import SwiftUI
import SwiftData

struct MainWindowView: View {
    @State private var selectedTask: ScheduledTask?
    @State private var showingEditor = false

    var body: some View {
        NavigationSplitView {
            TaskListView(selectedTask: $selectedTask)
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 350)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showingEditor = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help(L10n.tr("command.new_task"))
                    }
                }
        } detail: {
            if let task = selectedTask {
                TaskDetailView(task: task)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("task.select.title"), systemImage: "checklist")
                } description: {
                    Text(L10n.tr("task.select.description"))
                }
            }
        }
        .sheet(isPresented: $showingEditor) {
            TaskEditorView(task: nil)
        }
    }
}
