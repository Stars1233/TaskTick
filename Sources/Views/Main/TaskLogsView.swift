import SwiftUI
import SwiftData

struct TaskLogsView: View {
    @Environment(\.dismiss) private var dismiss
    let task: ScheduledTask

    @State private var selectedLog: ExecutionLog?

    var sortedLogs: [ExecutionLog] {
        task.executionLogs.sorted { $0.startedAt > $1.startedAt }
    }

    var body: some View {
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
        .frame(minWidth: 750, minHeight: 480)
    }
}

private struct LogDetailContent: View {
    let log: ExecutionLog

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard {
                    VStack(spacing: 8) {
                        row(L10n.tr("log.detail.trigger"), value: log.triggeredBy == .manual ? L10n.tr("log.detail.trigger.manual") : L10n.tr("log.detail.trigger.schedule"))

                        if let code = log.exitCode {
                            row(L10n.tr("log.detail.exit_code"), value: "\(code)")
                        }

                        if let ms = log.durationMs {
                            row(L10n.tr("log.detail.duration"), value: L10n.tr("log.detail.duration_ms", ms))
                        }

                        if let finished = log.finishedAt {
                            row(L10n.tr("log.detail.finished"), value: finished.formatted(date: .abbreviated, time: .standard))
                        }
                    }
                }

                if let stdout = log.stdout, !stdout.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.tr("log.detail.stdout"), systemImage: "text.alignleft")
                            .font(.headline)
                        Text(stdout)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                    }
                }

                if let stderr = log.stderr, !stderr.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(L10n.tr("log.detail.stderr"), systemImage: "exclamationmark.triangle")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(stderr)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.red.opacity(0.2), lineWidth: 0.5))
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
