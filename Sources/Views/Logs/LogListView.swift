import SwiftUI
import SwiftData

struct LogListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ExecutionLog.startedAt, order: .reverse) private var logs: [ExecutionLog]
    @State private var selectedLog: ExecutionLog?
    @State private var statusFilter: ExecutionStatus?

    var filteredLogs: [ExecutionLog] {
        if let filter = statusFilter {
            return logs.filter { $0.status == filter }
        }
        return Array(logs)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Filter chips
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: L10n.tr("log.filter.all"), isSelected: statusFilter == nil) {
                            statusFilter = nil
                        }
                        ForEach(ExecutionStatus.allCases, id: \.self) { status in
                            FilterChip(
                                label: status.displayName,
                                color: statusColor(status),
                                isSelected: statusFilter == status
                            ) {
                                statusFilter = (statusFilter == status) ? nil : status
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }

                if filteredLogs.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 32))
                            .foregroundStyle(.quaternary)
                        Text(L10n.tr("task.detail.no_logs"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    List(selection: $selectedLog) {
                        ForEach(filteredLogs) { log in
                            LogListRow(log: log)
                                .tag(log)
                        }
                    }
                    .listStyle(.sidebar)
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let log = selectedLog {
                LogDetailView(log: log)
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("log.select.title"), systemImage: "doc.text")
                } description: {
                    Text(L10n.tr("log.select.description"))
                }
            }
        }
    }

    private func statusColor(_ status: ExecutionStatus) -> Color {
        switch status {
        case .running: .blue
        case .success: .green
        case .failure: .red
        case .timeout: .orange
        case .cancelled: .gray
        }
    }
}

struct FilterChip: View {
    let label: String
    var color: Color = .accentColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isSelected ? color.opacity(0.15) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? color.opacity(0.5) : Color.secondary.opacity(0.2), lineWidth: 1))
                .foregroundStyle(isSelected ? color : .secondary)
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

struct LogListRow: View {
    let log: ExecutionLog

    var body: some View {
        HStack(spacing: 10) {
            StatusBadge(status: log.status, compact: true)

            VStack(alignment: .leading, spacing: 3) {
                Text(log.task?.name ?? L10n.tr("log.unknown_task"))
                    .font(.system(.body, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()

                    if let duration = log.durationMs {
                        Text("· \(duration)ms")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
