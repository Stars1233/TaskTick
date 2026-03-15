import Testing
@testable import TaskTick

@Suite("ScriptExecutor Tests")
struct ScriptExecutorTests {

    @Test("Executor singleton exists")
    @MainActor
    func executorExists() {
        let executor = ScriptExecutor.shared
        #expect(executor != nil)
    }
}
