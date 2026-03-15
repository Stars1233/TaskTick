import SwiftUI
import SwiftData

enum TaskFilter: String, CaseIterable {
    case all
    case enabled
    case disabled

    var label: String {
        switch self {
        case .all: L10n.tr("task.filter.all")
        case .enabled: L10n.tr("task.filter.enabled")
        case .disabled: L10n.tr("task.filter.disabled")
        }
    }
}

struct TaskListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledTask.updatedAt, order: .reverse) private var tasks: [ScheduledTask]
    @Binding var selectedTask: ScheduledTask?
    @State private var filter: TaskFilter = .all
    @State private var searchText = ""
    @StateObject private var scheduler = TaskScheduler.shared

    var filteredTasks: [ScheduledTask] {
        tasks.filter { task in
            let matchesFilter: Bool = switch filter {
            case .all: true
            case .enabled: task.isEnabled
            case .disabled: !task.isEnabled
            }
            let matchesSearch = searchText.isEmpty || task.name.localizedCaseInsensitiveContains(searchText)
            return matchesFilter && matchesSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter bar
            Picker("", selection: $filter) {
                ForEach(TaskFilter.allCases, id: \.self) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if filteredTasks.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "text.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.quaternary)
                    Text(L10n.tr("task.empty.title"))
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(L10n.tr("task.empty.description"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)
                Spacer()
            } else {
                List(selection: $selectedTask) {
                    ForEach(filteredTasks) { task in
                        TaskListRow(
                            task: task,
                            isRunning: scheduler.runningTaskIDs.contains(task.id)
                        )
                        .tag(task)
                        .contextMenu {
                            Button(L10n.tr("task.detail.run"), systemImage: "play.fill") {
                                Task {
                                    _ = await ScriptExecutor.shared.execute(task: task, modelContext: modelContext)
                                }
                            }
                            Divider()
                            Button(L10n.tr("task.detail.delete"), role: .destructive) {
                                modelContext.delete(task)
                                try? modelContext.save()
                                if selectedTask == task { selectedTask = nil }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $searchText, prompt: Text(L10n.tr("task.search.prompt")))
    }
}

struct TaskListRow: View {
    let task: ScheduledTask
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                if isRunning {
                    Circle()
                        .fill(.blue)
                        .frame(width: 10, height: 10)
                    Circle()
                        .stroke(.blue.opacity(0.3), lineWidth: 2)
                        .frame(width: 16, height: 16)
                } else {
                    Circle()
                        .fill(task.isEnabled ? .green : .gray.opacity(0.35))
                        .frame(width: 10, height: 10)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.name)
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    Image(systemName: task.schedule == .cron ? "clock" : "timer")
                        .font(.system(size: 9))

                    if task.schedule == .cron {
                        Text(task.cronExpression ?? "")
                            .font(.system(.caption2, design: .monospaced))
                    } else {
                        Text(L10n.tr("task.interval.seconds", task.intervalSeconds ?? 0))
                            .font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
    }
}
