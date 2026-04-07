import Foundation

/// Shared state for the task editor window.
@MainActor
final class EditorState: ObservableObject {
    static let shared = EditorState()

    @Published var taskToEdit: ScheduledTask?
    @Published var isPresented = false
    @Published var lastSavedTask: ScheduledTask?
    @Published var pendingTemplate: ScriptTemplate?
    /// Incremented on every open call to force TaskEditorView to reload.
    @Published var openTrigger = 0

    private init() {}

    func openNew() {
        taskToEdit = nil
        pendingTemplate = nil
        openTrigger += 1
        isPresented = true
    }

    func openNewFromTemplate(_ template: ScriptTemplate) {
        taskToEdit = nil
        pendingTemplate = template
        openTrigger += 1
        isPresented = true
    }

    func openEdit(_ task: ScheduledTask) {
        taskToEdit = task
        pendingTemplate = nil
        openTrigger += 1
        isPresented = true
    }

    func close() {
        isPresented = false
        taskToEdit = nil
        pendingTemplate = nil
    }
}
