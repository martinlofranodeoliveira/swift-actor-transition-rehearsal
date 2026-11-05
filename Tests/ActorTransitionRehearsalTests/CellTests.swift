import Testing
@testable import ActorTransitionRehearsal

@Test
func completionBeforeInstallationIsRetainedAndDuplicateObservationRejected() async throws {
    let cell = OneShot<Int>()
    #expect(cell.finish(17))
    #expect(!cell.finish(99))
    let result = try await cell.wait()
    #expect(result == 17)
    do {
        _ = try await cell.wait()
        Issue.record("A second observer was accepted")
    } catch { #expect(error as? LabError == .observerAlreadyUsed) }
}

@Test
func cancellationAfterInstallationResumesOnlyOnce() async throws {
    for _ in 0..<32 {
        let cell = OneShot<Wake>()
        let installed = OneShot<Bool>()
        let task = Task {
            try await withTaskCancellationHandler {
                try await cell.wait { installed.finish(true) }
            } onCancel: {
                cell.finish(.cancelled)
            }
        }
        _ = try await installed.wait()
        task.cancel()
        let result = try await task.value
        #expect(result == .cancelled)
        #expect(!cell.finish(.released))
        #expect(!cell.finish(.cancelled))
    }
}

@Test
func concurrentCompletionsHaveExactlyOneWinnerWithoutPredictingTheWinner() async throws {
    for _ in 0..<32 {
        let cell = OneShot<Int>()
        let wins = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            group.addTask { cell.finish(1) }
            group.addTask { cell.finish(2) }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        let result = try await cell.wait()
        #expect(wins == 1)
        #expect(result == 1 || result == 2)
    }
}
