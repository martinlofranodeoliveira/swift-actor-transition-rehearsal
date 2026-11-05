import Foundation
import Testing
@testable import ActorTransitionRehearsal

private func expectError(_ expected: LabError, _ body: () async throws -> Void) async throws {
    do {
        try await body()
        Issue.record("Expected a rejection")
    } catch {
        #expect(error as? LabError == expected)
    }
}

@Test @MainActor
func acknowledgedScenariosAreRepeatableAndHaveIndependentExpectedOutcomes() async throws {
    let first = try await Rehearsals.runAll()
    let second = try await Rehearsals.runAll()
    #expect(try first.canonicalJSON() == second.canonicalJSON())
    #expect(first.scenarios.map(\.name) == ["stale", "capacity", "pre-cancel-task", "suspended-cancel-task", "resumed-cancel-task", "application-cancel", "commit-then-cancel", "snapshot"])
    let outcomes = first.scenarios.map { $0.snapshot.operations.compactMap { $0.receipt?.outcome } }
    #expect(outcomes == [[.stale], [.committed, .cancelled], [.cancelled], [.cancelled], [.cancelled], [.cancelled], [.committed], [.committed]])
    let stale = first.scenarios[0].snapshot
    #expect(stale.journal.map(\.kind) == ["admitted", "executing", "registered", "generationChanged", "released", "cleaning", "removed", "terminal"])
    #expect(stale.generation == 1)
    #expect(stale.committedCount == 0)
    #expect(stale.operations[0].receipt?.completionGeneration == 1)
    let late = first.scenarios[6].snapshot.operations[0]
    #expect(late.receipt?.outcome == .committed)
    #expect(late.cancellation?.disposition == .tooLate)
}

@Test
func invalidInputsAndForeignTokensDoNotMutateEvidence() async throws {
    do {
        _ = try Limits(capacity: 0)
        Issue.record("Zero capacity accepted")
    } catch { #expect(error as? LabError == .invalidLimits) }
    do {
        _ = try Limits(journalEvents: 8193)
        Issue.record("Excessive journal accepted")
    } catch { #expect(error as? LabError == .invalidLimits) }
    let ledger = Rehearsal(limits: try Limits())
    let empty = await ledger.snapshot()
    for id in ["", "a/b", "ação", String(repeating: "a", count: 65), "a\n"] {
        try await expectError(.invalidIdentifier) { _ = try await ledger.admit(id) }
    }
    let afterInvalid = await ledger.snapshot()
    #expect(try empty.canonicalJSON() == afterInvalid.canonicalJSON())
    let token = try await ledger.admit("alpha")
    let before = await ledger.snapshot()
    try await expectError(.duplicateIdentifier) { _ = try await ledger.admit("alpha") }
    let foreign = Rehearsal(limits: try Limits())
    _ = try await foreign.admit("alpha")
    try await expectError(.foreignToken) { _ = try await foreign.cancel(token) }
    try await expectError(.foreignToken) { _ = try await foreign.execute(token) }
    let after = await ledger.snapshot()
    #expect(try before.canonicalJSON() == after.canonicalJSON())
    _ = try await ledger.cancel(token)
    let receipt = try await ledger.execute(token)
    #expect(receipt.outcome == .cancelled)
    try await expectError(.alreadyExecuting) { _ = try await ledger.execute(token) }
}

@Test
func waiterReceiptRecordLiveAndJournalLimitsPreserveCanonicalSnapshots() async throws {
    let configurations: [(Limits, LabError)] = [
        (try Limits(capacity: 2, liveOperations: 1), .liveLimit),
        (try Limits(capacity: 2, barrierWaiters: 1), .waiterLimit),
        (try Limits(capacity: 2, retainedOperationRecords: 1), .recordLimit),
        (try Limits(capacity: 2, terminalReceipts: 1), .receiptLimit),
        (try Limits(capacity: 2, journalEvents: 10), .journalLimit)
    ]
    for (limits, error) in configurations {
        let ledger = Rehearsal(limits: limits)
        let a = try await ledger.admit("alpha")
        let before = await ledger.snapshot()
        try await expectError(error) { _ = try await ledger.admit("beta") }
        let after = await ledger.snapshot()
        #expect(try before.canonicalJSON() == after.canonicalJSON())
        _ = try await ledger.cancel(a)
        let receipt = try await ledger.execute(a)
        let terminal = await ledger.snapshot()
        let waiters = await ledger.registeredWaiters()
        #expect(receipt.outcome == .cancelled)
        #expect(terminal.reservedCapacity == 0)
        #expect(terminal.reservedReceiptSlots == 0)
        #expect(waiters == 0)
    }
    let tiny = Rehearsal(limits: try Limits(journalEvents: 9))
    let before = await tiny.snapshot()
    try await expectError(.journalLimit) { _ = try await tiny.admit("alpha") }
    let after = await tiny.snapshot()
    #expect(try before.canonicalJSON() == after.canonicalJSON())
}

@Test
func terminalEvidenceIsNotEvictedAndCancellationIsIdempotent() async throws {
    let ledger = Rehearsal(limits: try Limits(capacity: 1, terminalReceipts: 1))
    let token = try await ledger.admit("alpha")
    let ack = try await ledger.cancel(token)
    let receipt = try await ledger.execute(token)
    let terminal = await ledger.snapshot()
    let repeated = try await ledger.cancel(token)
    let afterRepeated = await ledger.snapshot()
    #expect(ack == repeated)
    #expect(receipt.outcome == .cancelled)
    #expect(try terminal.canonicalJSON() == afterRepeated.canonicalJSON())
    try await expectError(.receiptLimit) { _ = try await ledger.admit("beta") }
    let afterRejected = await ledger.snapshot()
    #expect(try terminal.canonicalJSON() == afterRejected.canonicalJSON())
    var independentArray = terminal.operations
    independentArray.removeAll()
    #expect(independentArray.isEmpty)
    #expect(afterRejected.operations.count == 1)
}

@Test
func reservedJournalCannotBeConsumedByGenerationChanges() async throws {
    let ledger = Rehearsal(limits: try Limits(journalEvents: 10))
    let token = try await ledger.admit("alpha")
    let before = await ledger.snapshot()
    try await expectError(.journalLimit) { _ = try await ledger.invalidate() }
    let after = await ledger.snapshot()
    #expect(try before.canonicalJSON() == after.canonicalJSON())
    _ = try await ledger.cancel(token)
    let receipt = try await ledger.execute(token)
    let end = await ledger.snapshot()
    #expect(receipt.outcome == .cancelled)
    #expect(end.journal.count <= 10)
    #expect(end.reservedJournalEvents == 0)
}
