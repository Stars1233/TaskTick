import Testing
@testable import TaskTick

@Suite("TaskScheduler Tests")
struct TaskSchedulerTests {

    @Test("Scheduler singleton exists")
    @MainActor
    func schedulerExists() {
        let scheduler = TaskScheduler.shared
        #expect(scheduler.isRunning == false)
    }
}
