import SwiftUI
import SwiftData
import TaskTickCore

struct MainWindowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @StateObject private var editorState = EditorState.shared
    @StateObject private var mainSelection = MainWindowSelection.shared
    @State private var selectedTask: ScheduledTask?
    @AppStorage("taskSortOption") private var sortOptionRaw = TaskSortOption.lastRunDesc.rawValue
    @Binding var showingCrontabImport: Bool

    var body: some View {
        NavigationSplitView {
            TaskListView(selectedTask: $selectedTask, sortOptionRaw: $sortOptionRaw)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 350)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Menu {
                            Picker(L10n.tr("task.sort.created"), selection: $sortOptionRaw) {
                                Text(L10n.tr("task.sort.descending")).tag(TaskSortOption.createdDesc.rawValue)
                                Text(L10n.tr("task.sort.ascending")).tag(TaskSortOption.createdAsc.rawValue)
                            }
                            .pickerStyle(.inline)
                            Picker(L10n.tr("task.sort.last_run"), selection: $sortOptionRaw) {
                                Text(L10n.tr("task.sort.descending")).tag(TaskSortOption.lastRunDesc.rawValue)
                                Text(L10n.tr("task.sort.ascending")).tag(TaskSortOption.lastRunAsc.rawValue)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            EditorState.shared.openNew()
                            openWindow(id: "editor")
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("command.new_task"))
                    }
                }
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
                    .id(task.id)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("task.select.title"), systemImage: "checklist")
                } description: {
                    Text(L10n.tr("task.select.description"))
                }
            }
        }
        .sheet(isPresented: $showingCrontabImport) {
            CrontabImportView()
        }
        .onChange(of: editorState.lastSavedTask) { _, newTask in
            if let task = newTask {
                selectedTask = task
                editorState.lastSavedTask = nil
            }
        }
        .onAppear {
            // Capture `openWindow` so AppDelegate / other non-View contexts
            // can reopen the main window after it's been closed (Window(id:)
            // destroys the NSWindow on close — only SwiftUI's openWindow
            // can resurrect it).
            WindowOpener.shared.openMain = { openWindow(id: "main") }

            // When Quick Launcher opens the main window via ⌘O, the window
            // scene may instantiate fresh — pick up the rendezvous selection
            // here so the first render already shows the requested task.
            if let task = mainSelection.taskToReveal {
                selectedTask = task
                mainSelection.taskToReveal = nil
            }
        }
        .onChange(of: mainSelection.taskToReveal) { _, newTask in
            if let task = newTask {
                selectedTask = task
                mainSelection.taskToReveal = nil
            }
        }
    }
}
