import Foundation

public enum LabError: String, Error, Sendable, Equatable, CustomStringConvertible {
    case invalidLimits, invalidIdentifier, duplicateIdentifier
    case capacityLimit, liveLimit, waiterLimit, recordLimit, receiptLimit, journalLimit
    case counterOverflow, foreignToken, alreadyExecuting, observerAlreadyUsed
    case invariantViolation, invalidArguments, assertionFailed, incompleteScenario
    public var description: String { rawValue }
}

public struct Limits: Sendable, Equatable, Encodable {
    public let capacity: Int
    public let liveOperations: Int
    public let barrierWaiters: Int
    public let retainedOperationRecords: Int
    public let terminalReceipts: Int
    public let journalEvents: Int

    public init(capacity: Int = 2, liveOperations: Int = 16, barrierWaiters: Int = 16,
                retainedOperationRecords: Int = 64, terminalReceipts: Int = 64,
                journalEvents: Int = 1024) throws {
        guard (1...64).contains(capacity), (1...128).contains(liveOperations),
              (1...128).contains(barrierWaiters), (1...1024).contains(retainedOperationRecords),
              (1...1024).contains(terminalReceipts), (1...8192).contains(journalEvents) else {
            throw LabError.invalidLimits
        }
        self.capacity = capacity
        self.liveOperations = liveOperations
        self.barrierWaiters = barrierWaiters
        self.retainedOperationRecords = retainedOperationRecords
        self.terminalReceipts = terminalReceipts
        self.journalEvents = journalEvents
    }
}

public enum Outcome: String, Sendable, Encodable { case committed, stale, cancelled, failed }
public enum Phase: String, Sendable, Encodable { case admitted, registering, waiting, resumed, cleaning, terminal }
public enum Gate: String, Sendable, Encodable { case suspension, commit }
public enum RegistrationDisposition: String, Sendable, Encodable {
    case registered, cancelledBeforeRegistration, rejected
}
public enum CancellationDisposition: String, Sendable, Encodable { case requested, tooLate, terminal }
public enum ReleaseAcknowledgement: String, Sendable, Encodable {
    case released, alreadyReleased, notReady, terminal
}

public struct Receipt: Sendable, Equatable, Encodable {
    public let operation: String
    public let sequence: UInt64
    public let admissionGeneration: UInt64
    public let completionGeneration: UInt64
    public let outcome: Outcome
}
public struct RegistrationAcknowledgement: Sendable, Encodable {
    public let operation: String
    public let sequence: UInt64
    public let disposition: RegistrationDisposition
}
public struct ResumptionAcknowledgement: Sendable, Encodable {
    public let operation: String
    public let sequence: UInt64
    public let waitingForCommit: Bool
    public let terminalOutcome: Outcome?
}
public struct CancellationAcknowledgement: Sendable, Equatable, Encodable {
    public let sequence: UInt64
    public let disposition: CancellationDisposition
}
public struct JournalEvent: Sendable, Encodable {
    public let sequence: UInt64
    public let generation: UInt64
    public let operation: String?
    public let kind: String
    public let detail: String?
}
public struct OperationSnapshot: Sendable, Encodable {
    public let id: String
    public let admissionSequence: UInt64
    public let generation: UInt64
    public let phase: Phase
    public let receipt: Receipt?
    public let cancellation: CancellationAcknowledgement?
}
public struct Snapshot: Sendable, Encodable {
    public let limits: Limits
    public let generation: UInt64
    public let committedCount: UInt64
    public let liveOperations: Int
    public let reservedCapacity: Int
    public let reservedWaiterSlots: Int
    public let reservedReceiptSlots: Int
    public let retainedReceipts: Int
    public let retainedOperationRecords: Int
    public let reservedJournalEvents: Int
    public let operations: [OperationSnapshot]
    public let journal: [JournalEvent]

    public func canonicalJSON() throws -> Data { try Canonical.encode(self) }
}
public enum Canonical {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

public struct OperationToken: Sendable {
    public let id: String
    public let generation: UInt64
    public let ticket: UInt64
    let control: OperationControl

    public func registration() async throws -> RegistrationAcknowledgement {
        try await control.registration.wait()
    }
    public func resumption() async throws -> ResumptionAcknowledgement {
        try await control.resumption.wait()
    }
}
