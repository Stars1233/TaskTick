import Foundation

/// Shared state for the task editor window.
@MainActor
final class EditorState: ObservableObject {
    static let shared = EditorState()

    @Published var taskToEdit: ScheduledTask?
    @Published var isPresented = false

    private init() {}

    func openNew() {
        taskToEdit = nil
        isPresented = true
    }

    func openEdit(_ task: ScheduledTask) {
        taskToEdit = task
        isPresented = true
    }

    func close() {
        isPresented = false
        taskToEdit = nil
    }
}
