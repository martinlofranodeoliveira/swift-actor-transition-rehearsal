public actor Rehearsal {
    // Includes admission, both releases, cleanup, terminal and one application
    // cancellation acknowledgement, even when that acknowledgement is too late.
    public static let journalSlotsPerAdmission = 10

    private final class Record {
        let token: OperationToken
        var phase: Phase = .admitted
        var receipt: Receipt?
        var cancellation: CancellationAcknowledgement?
        var journalBudget = Rehearsal.journalSlotsPerAdmission
        var firstReleased = false
        var secondReleased = false
        init(token: OperationToken) { self.token = token }
    }

    private let limits: Limits
    private let barrier: OwnedBarrier
    private var records: [String: Record] = [:]
    private var journal: [JournalEvent] = []
    private var sequence: UInt64 = 0
    private var generation: UInt64 = 0
    private var committed: UInt64 = 0
    private var live = 0
    private var reservedEvents = 0

    public init(limits: Limits) {
        self.limits = limits
        self.barrier = OwnedBarrier(limit: limits.barrierWaiters)
    }

    public func admit(_ id: String) throws -> OperationToken {
        let bytes = id.utf8
        guard (1...64).contains(bytes.count), bytes.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }) else { throw LabError.invalidIdentifier }
        guard records[id] == nil else { throw LabError.duplicateIdentifier }
        guard live < limits.capacity else { throw LabError.capacityLimit }
        guard live < limits.liveOperations else { throw LabError.liveLimit }
        guard live < limits.barrierWaiters else { throw LabError.waiterLimit }
        guard records.count < limits.retainedOperationRecords else { throw LabError.recordLimit }
        guard records.count < limits.terminalReceipts else { throw LabError.receiptLimit }
        let slots = Self.journalSlotsPerAdmission
        guard journal.count + reservedEvents + slots <= limits.journalEvents else { throw LabError.journalLimit }
        let future = sequence.addingReportingOverflow(UInt64(reservedEvents + slots))
        guard !future.overflow else { throw LabError.counterOverflow }
        let next = sequence.addingReportingOverflow(1)
        guard !next.overflow else { throw LabError.counterOverflow }
        let token = OperationToken(id: id, generation: generation, ticket: next.partialValue,
                                   control: OperationControl())
        let record = Record(token: token)
        records[id] = record
        live += 1
        reservedEvents += slots
        _ = try append("admitted", record: record)
        return token
    }

    public func invalidate() throws -> UInt64 {
        let next = generation.addingReportingOverflow(1)
        guard !next.overflow else { throw LabError.counterOverflow }
        _ = try append("generationChanged", eventGeneration: next.partialValue)
        generation = next.partialValue
        return generation
    }

    public func cancel(_ token: OperationToken) throws -> CancellationAcknowledgement {
        let record = try require(token)
        if let previous = record.cancellation { return previous }
        // Cancellation and terminal decision share a synchronous Mutex checkpoint.
        // No await or forwarding task exists between the request and its receipt.
        let disposition = token.control.requestCancellation()
        let seq = try append("cancellationAcknowledged", record: record, detail: disposition.rawValue)
        let ack = CancellationAcknowledgement(sequence: seq, disposition: disposition)
        record.cancellation = ack
        return ack
    }

    public func execute(_ token: OperationToken) async throws -> Receipt {
        let record = try require(token)
        guard record.phase == .admitted else { throw LabError.alreadyExecuting }
        _ = try append("executing", record: record)
        record.phase = .registering
        return try await withTaskCancellationHandler {
            do {
                return try await self.executeBody(token)
            } catch {
                // Unexpected internal failures still attempt owned cleanup and a
                // failed receipt; caller-input errors above never enter this path.
                token.control.requestCancellation()
                _ = await self.barrier.remove(ticket: token.ticket)
                return try self.finish(token, failed: true)
            }
        } onCancel: {
            token.control.requestCancellation()
        }
    }

    private func executeBody(_ token: OperationToken) async throws -> Receipt {
        let record = try require(token)
        let disposition = await barrier.register(ticket: token.ticket, control: token.control)
        let initialInvalidity = try checkpoint(record)
        let registeredSequence = try append("registered", record: record, detail: disposition.rawValue)
        record.phase = .waiting
        let registration = RegistrationAcknowledgement(operation: token.id, sequence: registeredSequence,
                                                       disposition: disposition)
        if initialInvalidity != nil || disposition != .registered {
            token.control.first.finish(token.control.isCancelled ? .cancelled : .released)
        }
        let first = try await token.control.first.wait {
            token.control.registration.finish(registration)
        }
        let afterFirst = try checkpoint(record)
        if first == .released, afterFirst == nil, disposition == .registered {
            let seq = try append("resumed", record: record)
            record.phase = .resumed
            let acknowledgement = ResumptionAcknowledgement(operation: token.id, sequence: seq,
                                                            waitingForCommit: true, terminalOutcome: nil)
            _ = try await token.control.second.wait {
                token.control.resumption.finish(acknowledgement)
            }
            _ = try checkpoint(record)
        }
        _ = try append("cleaning", record: record)
        record.phase = .cleaning
        let removed = await barrier.remove(ticket: token.ticket)
        _ = try checkpoint(record)
        _ = try append("removed", record: record, detail: removed ? "true" : "false")
        return try finish(token, failed: disposition == .rejected)
    }

    public func release(_ token: OperationToken, at gate: Gate) async throws -> ReleaseAcknowledgement {
        let record = try require(token)
        if record.receipt != nil { return .terminal }
        if gate == .suspension && record.firstReleased { return .alreadyReleased }
        if gate == .commit && record.secondReleased { return .alreadyReleased }
        let requiredPhase: Phase = gate == .suspension ? .waiting : .resumed
        guard record.phase == requiredPhase else { return .notReady }
        let permit = await barrier.prepareRelease(ticket: token.ticket, gate: gate)
        // The actor could have processed cancellation/cleanup during that await.
        _ = try require(token)
        if record.receipt != nil { return .terminal }
        guard record.phase == requiredPhase else { return .notReady }
        switch permit {
        case .missing: return .notReady
        case .alreadyReleased: return .alreadyReleased
        case .permitted:
            _ = try append("released", record: record, detail: gate.rawValue)
            if gate == .suspension {
                record.firstReleased = true
                token.control.first.finish(.released)
            } else {
                record.secondReleased = true
                token.control.second.finish(.released)
            }
            return .released
        }
    }

    // This inspection acknowledges the barrier actor's table at this call, not
    // an atomic combined snapshot of both actors. Joined terminal runs have zero.
    public func registeredWaiters() async -> Int { await barrier.count() }

    public func snapshot() -> Snapshot {
        let operations = records.values.map { record in
            OperationSnapshot(id: record.token.id, admissionSequence: record.token.ticket,
                              generation: record.token.generation, phase: record.phase,
                              receipt: record.receipt, cancellation: record.cancellation)
        }.sorted { $0.id < $1.id }
        return Snapshot(limits: limits, generation: generation, committedCount: committed,
                        liveOperations: live, reservedCapacity: live, reservedWaiterSlots: live,
                        reservedReceiptSlots: live, retainedReceipts: records.count - live,
                        retainedOperationRecords: records.count, reservedJournalEvents: reservedEvents,
                        operations: operations, journal: journal)
    }

    private func require(_ token: OperationToken) throws -> Record {
        guard let record = records[token.id], record.token.control === token.control,
              record.token.ticket == token.ticket, record.token.generation == token.generation else {
            throw LabError.foreignToken
        }
        return record
    }

    private func checkpoint(_ record: Record) throws -> Outcome? {
        guard record.receipt == nil, live > 0,
              records[record.token.id] === record else { throw LabError.invariantViolation }
        if record.token.control.isCancelled { return .cancelled }
        if record.token.generation != generation { return .stale }
        return nil
    }

    private func finish(_ token: OperationToken, failed: Bool) throws -> Receipt {
        let record = try require(token)
        if let receipt = record.receipt { return receipt }
        _ = try checkpoint(record)
        let nextCommitted = committed.addingReportingOverflow(1)
        guard !nextCommitted.overflow else { throw LabError.counterOverflow }
        let outcome = token.control.decide(stale: token.generation != generation, failed: failed)
        let seq = try append("terminal", record: record, detail: outcome.rawValue)
        let receipt = Receipt(operation: token.id, sequence: seq, admissionGeneration: token.generation,
                              completionGeneration: generation, outcome: outcome)
        if outcome == .committed { committed = nextCommitted.partialValue }
        record.receipt = receipt
        record.phase = .terminal
        live -= 1
        // Retain one reserved slot for the first post-terminal application cancel.
        let keep = record.cancellation == nil ? 1 : 0
        guard record.journalBudget >= keep else { throw LabError.invariantViolation }
        reservedEvents -= record.journalBudget - keep
        record.journalBudget = keep
        token.control.resumption.finish(ResumptionAcknowledgement(operation: token.id, sequence: seq,
                                                                 waitingForCommit: false, terminalOutcome: outcome))
        return receipt
    }

    @discardableResult
    private func append(_ kind: String, record: Record? = nil, detail: String? = nil,
                        eventGeneration: UInt64? = nil) throws -> UInt64 {
        if let record {
            guard record.journalBudget > 0, reservedEvents > 0,
                  journal.count < limits.journalEvents else { throw LabError.invariantViolation }
        } else {
            guard journal.count + reservedEvents < limits.journalEvents else { throw LabError.journalLimit }
        }
        let next = sequence.addingReportingOverflow(1)
        guard !next.overflow else { throw LabError.counterOverflow }
        if let record {
            record.journalBudget -= 1
            reservedEvents -= 1
        }
        sequence = next.partialValue
        journal.append(JournalEvent(sequence: sequence, generation: eventGeneration ?? generation,
                                    operation: record?.token.id, kind: kind, detail: detail))
        return sequence
    }
}
