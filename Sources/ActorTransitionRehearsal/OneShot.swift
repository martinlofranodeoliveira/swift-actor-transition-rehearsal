import Synchronization

// One installation, one completion. Completion may precede installation.
final class OneShot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var continuation: CheckedContinuation<Value, any Error>?
        var installed = false
    }
    private let state = Mutex(State())

    @discardableResult
    func finish(_ value: Value) -> Bool {
        let result: (Bool, CheckedContinuation<Value, any Error>?) = state.withLock { state in
            guard state.value == nil else { return (false, nil) }
            state.value = value
            let continuation = state.continuation
            state.continuation = nil
            return (true, continuation)
        }
        result.1?.resume(returning: value)
        return result.0
    }

    func wait(onInstalled: @Sendable () -> Void = {}) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let immediate: Result<Value, LabError>? = state.withLock { state in
                guard !state.installed else { return .failure(.observerAlreadyUsed) }
                state.installed = true
                if let value = state.value { return .success(value) }
                state.continuation = continuation
                return nil
            }
            // This callback acknowledges completed installation, not entry into wait().
            onInstalled()
            if let immediate {
                switch immediate {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

enum Wake: Sendable { case released, cancelled }

final class OperationControl: Sendable {
    private struct State {
        var cancellationRequested = false
        var decision: Outcome?
    }
    private let state = Mutex(State())
    let first = OneShot<Wake>()
    let second = OneShot<Wake>()
    let registration = OneShot<RegistrationAcknowledgement>()
    let resumption = OneShot<ResumptionAcknowledgement>()

    var isCancelled: Bool { state.withLock { $0.cancellationRequested } }

    @discardableResult
    func requestCancellation() -> CancellationDisposition {
        let disposition: CancellationDisposition = state.withLock { state in
            if let decision = state.decision {
                return decision == .committed ? .tooLate : .terminal
            }
            state.cancellationRequested = true
            return .requested
        }
        if disposition == .requested {
            first.finish(.cancelled)
            second.finish(.cancelled)
        }
        return disposition
    }

    func decide(stale: Bool, failed: Bool) -> Outcome {
        state.withLock { state in
            if let decision = state.decision { return decision }
            let result: Outcome
            if failed { result = .failed }
            else if state.cancellationRequested { result = .cancelled }
            else if stale { result = .stale }
            else { result = .committed }
            state.decision = result
            return result
        }
    }
}
