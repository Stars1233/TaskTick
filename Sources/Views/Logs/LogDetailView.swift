import SwiftUI
import SwiftData

struct LogDetailView: View {
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
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .top, spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(statusGradient)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: log.status.iconName)
                                .font(.title3)
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(log.task?.name ?? L10n.tr("log.unknown_task"))
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(log.startedAt.formatted(date: .complete, time: .standard))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    StatusBadge(status: log.status)
                }

                Divider()

                // Info card
                GlassCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(L10n.tr("log.detail.title"), systemImage: "info.circle")
                            .font(.headline)

                        VStack(spacing: 8) {
                            infoRow(L10n.tr("log.detail.trigger"),
                                    value: log.triggeredBy == .manual
                                        ? L10n.tr("log.detail.trigger.manual")
                                        : L10n.tr("log.detail.trigger.schedule"))

                            if let exitCode = log.exitCode {
                                infoRow(L10n.tr("log.detail.exit_code"), value: "\(exitCode)")
                            }

                            if let duration = log.durationMs {
                                infoRow(L10n.tr("log.detail.duration"), value: L10n.tr("log.detail.duration_ms", duration))
                            }

                            if let finished = log.finishedAt {
                                infoRow(L10n.tr("log.detail.finished"),
                                        value: finished.formatted(date: .abbreviated, time: .standard))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Running indicator
                if log.status == .running {
                    GlassCard {
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

                // Output sections
                if let stdout = currentStdout, !stdout.isEmpty {
                    OutputSection(
                        title: L10n.tr("log.detail.stdout"),
                        content: stdout,
                        icon: "text.alignleft",
                        color: .primary
                    )
                }

                if let stderr = currentStderr, !stderr.isEmpty {
                    OutputSection(
                        title: L10n.tr("log.detail.stderr"),
                        content: stderr,
                        icon: "exclamationmark.triangle",
                        color: .red
                    )
                }
            }
            .padding(20)
        }
    }

    private var statusGradient: LinearGradient {
        let color: Color = switch log.status {
        case .running: .blue
        case .success: .green
        case .failure: .red
        case .timeout: .orange
        case .cancelled: .gray
        }
        return LinearGradient(
            colors: [color, color.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
        }
    }
}

struct OutputSection: View {
    let title: String
    let content: String
    let icon: String
    var color: Color = .primary

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: icon)
                    .font(.headline)
                    .foregroundStyle(color == .primary ? .primary : color)

                Text(content)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.black.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 0.5)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
