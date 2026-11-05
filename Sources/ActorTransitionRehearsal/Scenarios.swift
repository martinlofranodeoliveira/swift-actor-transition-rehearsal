import Foundation

public struct ScenarioEvidence: Sendable, Encodable {
    public let name: String
    public let snapshot: Snapshot
}
public struct DemoReport: Sendable, Encodable {
    public let version: String
    public let scenarios: [ScenarioEvidence]
    public func canonicalJSON() throws -> Data { try Canonical.encode(self) }
}

@MainActor
private final class RunOwner {
    private var tasks: [Task<Receipt, any Error>] = []

    func start(_ ledger: Rehearsal, _ token: OperationToken, preCancelled: Bool = false) throws -> Task<Receipt, any Error> {
        guard tasks.count < 16 else { throw LabError.incompleteScenario }
        let task = Task {
            if preCancelled { withUnsafeCurrentTask { $0?.cancel() } }
            return try await ledger.execute(token)
        }
        tasks.append(task)
        return task
    }
    func join() async throws {
        for task in tasks { _ = try await task.value }
    }
    func cancelAndJoin() async {
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
    }
}

public enum Rehearsals {
    @MainActor
    private static func owned(_ name: String, body: (RunOwner) async throws -> Snapshot) async throws -> ScenarioEvidence {
        let owner = RunOwner()
        do {
            let snapshot = try await body(owner)
            try await owner.join()
            return ScenarioEvidence(name: name, snapshot: snapshot)
        } catch {
            await owner.cancelAndJoin()
            throw error
        }
    }

    private static func check(_ condition: Bool) throws {
        guard condition else { throw LabError.assertionFailed }
    }

    @MainActor
    private static func releaseBoth(_ ledger: Rehearsal, _ token: OperationToken) async throws {
        let first = try await ledger.release(token, at: .suspension)
        try check(first == .released)
        let resumed = try await token.resumption()
        try check(resumed.waitingForCommit)
        let second = try await ledger.release(token, at: .commit)
        try check(second == .released)
    }

    @MainActor
    public static func runAll() async throws -> DemoReport {
        var evidence: [ScenarioEvidence] = []
        evidence.append(try await owned("stale") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let task = try owner.start(ledger, token)
            let registered = try await token.registration()
            try check(registered.disposition == .registered)
            _ = try await ledger.invalidate()
            let release = try await ledger.release(token, at: .suspension)
            try check(release == .released)
            let receipt = try await task.value
            let snapshot = await ledger.snapshot()
            try check(receipt.outcome == .stale && snapshot.committedCount == 0 && snapshot.reservedCapacity == 0)
            let waiters = await ledger.registeredWaiters()
            try check(waiters == 0)
            return snapshot
        })
        evidence.append(try await owned("capacity") { owner in
            let ledger = Rehearsal(limits: try Limits(capacity: 2))
            let a = try await ledger.admit("alpha")
            let ta = try owner.start(ledger, a)
            _ = try await a.registration()
            let b = try await ledger.admit("beta")
            let tb = try owner.start(ledger, b)
            _ = try await b.registration()
            let full = await ledger.snapshot()
            try check(full.reservedCapacity == 2)
            let bytes = try full.canonicalJSON()
            do {
                _ = try await ledger.admit("gamma")
                throw LabError.assertionFailed
            } catch LabError.capacityLimit {}
            let unchanged = await ledger.snapshot()
            try check(try unchanged.canonicalJSON() == bytes)
            try await releaseBoth(ledger, a)
            let ra = try await ta.value
            let partial = await ledger.snapshot()
            try check(ra.outcome == .committed && partial.reservedCapacity == 1)
            let ack = try await ledger.cancel(b)
            try check(ack.disposition == .requested)
            let rb = try await tb.value
            let end = await ledger.snapshot()
            let waiters = await ledger.registeredWaiters()
            try check(rb.outcome == .cancelled && end.reservedCapacity == 0 && end.committedCount == 1 && waiters == 0)
            return end
        })
        evidence.append(try await owned("pre-cancel-task") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let task = try owner.start(ledger, token, preCancelled: true)
            let registration = try await token.registration()
            let receipt = try await task.value
            let snapshot = await ledger.snapshot()
            let waiters = await ledger.registeredWaiters()
            try check(registration.disposition == .cancelledBeforeRegistration && receipt.outcome == .cancelled)
            try check(snapshot.retainedReceipts == 1 && snapshot.reservedCapacity == 0 && waiters == 0)
            return snapshot
        })
        evidence.append(try await owned("suspended-cancel-task") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let task = try owner.start(ledger, token)
            let ack = try await token.registration()
            try check(ack.disposition == .registered)
            task.cancel()
            let receipt = try await task.value
            let snapshot = await ledger.snapshot()
            let waiters = await ledger.registeredWaiters()
            try check(receipt.outcome == .cancelled && snapshot.committedCount == 0 && waiters == 0)
            return snapshot
        })
        evidence.append(try await owned("resumed-cancel-task") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let task = try owner.start(ledger, token)
            _ = try await token.registration()
            let release = try await ledger.release(token, at: .suspension)
            try check(release == .released)
            let resumed = try await token.resumption()
            try check(resumed.waitingForCommit)
            task.cancel()
            let receipt = try await task.value
            let snapshot = await ledger.snapshot()
            let waiters = await ledger.registeredWaiters()
            try check(receipt.outcome == .cancelled && snapshot.committedCount == 0 && waiters == 0)
            return snapshot
        })
        evidence.append(try await owned("application-cancel") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let ack = try await ledger.cancel(token)
            let repeated = try await ledger.cancel(token)
            try check(ack == repeated && ack.disposition == .requested)
            let task = try owner.start(ledger, token)
            let registration = try await token.registration()
            let receipt = try await task.value
            let snapshot = await ledger.snapshot()
            try check(registration.disposition == .cancelledBeforeRegistration && receipt.outcome == .cancelled)
            try check(snapshot.retainedReceipts == 1 && snapshot.reservedCapacity == 0)
            return snapshot
        })
        evidence.append(try await owned("commit-then-cancel") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let task = try owner.start(ledger, token)
            _ = try await token.registration()
            try await releaseBoth(ledger, token)
            let receipt = try await task.value
            task.cancel()
            let ack = try await ledger.cancel(token)
            let snapshot = await ledger.snapshot()
            try check(receipt.outcome == .committed && ack.disposition == .tooLate)
            try check(receipt.sequence < ack.sequence && snapshot.committedCount == 1)
            return snapshot
        })
        evidence.append(try await owned("snapshot") { owner in
            let ledger = Rehearsal(limits: try Limits())
            let token = try await ledger.admit("alpha")
            let task = try owner.start(ledger, token)
            _ = try await token.registration()
            try await releaseBoth(ledger, token)
            let receipt = try await task.value
            let retained = await ledger.snapshot()
            let bytes = try retained.canonicalJSON()
            _ = try await ledger.invalidate()
            let changed = await ledger.snapshot()
            try check(receipt.outcome == .committed && changed.generation == 1)
            try check(try retained.canonicalJSON() == bytes)
            try check(try changed.canonicalJSON() != bytes)
            return changed
        })
        return DemoReport(version: "0.1.0", scenarios: evidence)
    }
}
