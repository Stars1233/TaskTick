import SwiftUI
import SwiftData

struct TaskLogsView: View {
    @Environment(\.dismiss) private var dismiss
    let task: ScheduledTask
    var initialSelectedLogId: UUID?

    @State private var selectedLog: ExecutionLog?

    var sortedLogs: [ExecutionLog] {
        task.executionLogs.filter { $0.modelContext != nil }.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
        Group {
            if sortedLogs.isEmpty {
                emptyView
            } else {
                splitView
            }
        }
        .frame(minWidth: 750, minHeight: 480)
        .onAppear {
            if selectedLog == nil {
                if let targetId = initialSelectedLogId {
                    selectedLog = sortedLogs.first { $0.id == targetId }
                }
                if selectedLog == nil {
                    selectedLog = sortedLogs.first
                }
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L10n.tr("log.empty.title"),
            systemImage: "tray",
            description: Text(L10n.tr("log.empty.description"))
        )
        .navigationTitle(task.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(L10n.tr("editor.cancel")) { dismiss() }
                    .pointerCursor()
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView {
            List(sortedLogs, selection: $selectedLog) { log in
                HStack(spacing: 8) {
                    StatusBadge(status: log.status, compact: true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(log.startedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.subheadline)
                        if let ms = log.durationMs {
                            Text("\(ms)ms")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                    }

                    Spacer()
                }
                .tag(log)
                .padding(.vertical, 2)
            }
            .frame(minWidth: 240)
            .navigationTitle(task.name)
            .navigationSubtitle("\(sortedLogs.count) \(L10n.tr("log.count_suffix"))")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.tr("editor.cancel")) { dismiss() }
                        .pointerCursor()
                }
            }
        } detail: {
            if let log = selectedLog {
                LogDetailContent(log: log)
            } else {
                ContentUnavailableView(
                    L10n.tr("log.select.title"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(L10n.tr("log.select.description"))
                )
            }
        }
    }
}

private struct LogDetailContent: View {
    let log: ExecutionLog
    @ObservedObject private var liveOutput = LiveOutputManager.shared

    private var currentStdout: String? {
        if log.status == .running,
           let taskId = log.task?.id,
           let live = liveOutput.liveOutputs[taskId] {
            return live.stdout.isEmpty ? nil : live.stdout
        }
        return log.stdout
    }

    private var currentStderr: String? {
        if log.status == .running,
           let taskId = log.task?.id,
           let live = liveOutput.liveOutputs[taskId] {
            return live.stderr.isEmpty ? nil : live.stderr
        }
        return log.stderr
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(spacing: 8) {
                        row(L10n.tr("log.detail.trigger"), value: log.triggeredBy.displayName)

                        if let code = log.exitCode {
                            row(L10n.tr("log.detail.exit_code"), value: "\(code)")
                        }

                        if let ms = log.durationMs {
                            row(L10n.tr("log.detail.duration"), value: L10n.tr("log.detail.duration_ms", ms))
                        }

                        if let finished = log.finishedAt {
                            row(L10n.tr("log.detail.finished"), value: finished.formatted(date: .abbreviated, time: .standard))
                        }

                        if log.status == .running {
                            HStack {
                                Text(L10n.tr("status.running"))
                                    .font(.subheadline)
                                    .foregroundStyle(.blue)
                                Spacer()
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                let combined = [currentStdout, currentStderr]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: "\n")
                if !combined.isEmpty {
                    let isFailure = log.status == .failure || log.status == .timeout
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.tr("log.detail.output"),
                              systemImage: isFailure ? "exclamationmark.triangle" : "text.alignleft")
                            .font(.headline)
                            .foregroundStyle(isFailure ? Color.red : Color.primary)
                        Text(combined)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(isFailure ? Color.red.opacity(0.04) : Color.black.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(isFailure ? Color.red.opacity(0.2) : Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                }
            }
            .padding()
        }
    }

    private func row(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }
}
