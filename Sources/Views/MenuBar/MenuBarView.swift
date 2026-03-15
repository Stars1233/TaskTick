import SwiftUI
import SwiftData

/// Content view displayed in the menu bar popover.
struct MenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScheduledTask.updatedAt, order: .reverse) private var tasks: [ScheduledTask]
    @StateObject private var scheduler = TaskScheduler.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.tint)
                Text(L10n.tr("app.name"))
                    .font(.headline)
                Spacer()
                Text("\(tasks.filter(\.isEnabled).count)/\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.quaternary)
                    Text(L10n.tr("menubar.no_tasks"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tasks.prefix(10)) { task in
                            MenuBarTaskRow(task: task, isRunning: scheduler.runningTaskIDs.contains(task.id))
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 320)
            }

            Divider()

            // Footer
            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows {
                    if window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }) {
                HStack {
                    Image(systemName: "macwindow")
                    Text(L10n.tr("menubar.open"))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .padding(.vertical, 4)
        }
        .frame(width: 300)
    }
}

struct MenuBarTaskRow: View {
    let task: ScheduledTask
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Status dot with animation
            ZStack {
                Circle()
                    .fill(isRunning ? .blue : (task.isEnabled ? .green : .gray.opacity(0.4)))
                    .frame(width: 8, height: 8)

                if isRunning {
                    Circle()
                        .stroke(.blue.opacity(0.4), lineWidth: 2)
                        .frame(width: 14, height: 14)
                        .scaleEffect(isRunning ? 1.3 : 1.0)
                        .opacity(isRunning ? 0 : 1)
                        .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: isRunning)
                }
            }
            .frame(width: 16)

            Text(task.name)
                .font(.system(.body, design: .default))
                .lineLimit(1)

            Spacer()

            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else if let nextRun = task.nextRunAt {
                Text(nextRun, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(0.00001)) // Hit area
        )
    }
}
