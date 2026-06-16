import AppKit
import SwiftUI
import TaskTickCore

/// A floating panel that displays full script output for strong reminders.
/// User must click "OK" to dismiss.
@MainActor
final class StrongReminderPanel {

    static let shared = StrongReminderPanel()

    private var panel: NSPanel?

    private init() {}

    func show(taskName: String, output: String, durationMs: Int?) {
        dismiss()

        let panelWidth: CGFloat = 420
        let minHeight: CGFloat = 160
        let maxHeight: CGFloat = 500
        let chrome: CGFloat = 110 // header + dividers + footer + padding

        // Calculate text height with line wrapping
        let displayText = output.isEmpty ? L10n.tr("notification.success") : output
        let charsPerLine = 48 // approximate for 420px - padding with 12pt monospace
        let wrappedLines = displayText.components(separatedBy: .newlines).reduce(0) { total, line in
            total + max(1, Int(ceil(Double(max(1, line.count)) / Double(charsPerLine))))
        }
        let textHeight = CGFloat(max(2, wrappedLines)) * 16 + 24
        let panelHeight = min(maxHeight, max(minHeight, chrome + textHeight))

        let content = StrongReminderView(
            taskName: taskName,
            output: output,
            durationMs: durationMs,
            onDismiss: { [weak self] in self?.dismiss() }
        )

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.title = "TaskTick\(L10n.tr("editor.strong_reminder_short")) - \(taskName)"
        panel.animationBehavior = .utilityWindow

        // Position near top-right of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - panel.frame.width - 20
            let y = screenFrame.maxY - panel.frame.height - 20
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func dismiss() {
        panel?.close()
        panel = nil
    }
}

struct StrongReminderView: View {
    let taskName: String
    let output: String
    let durationMs: Int?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(taskName)
                        .font(.headline)
                    if let ms = durationMs {
                        Text("\(L10n.tr("notification.duration")) \(ExecutionLog.formatDuration(ms))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(12)

            Divider()

            // Output
            ScrollView {
                Text(output.isEmpty ? L10n.tr("notification.success") : output)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(maxHeight: 380) // leave room for header + footer within 500 max

            Divider()

            // Footer
            HStack {
                Spacer()
                Button(L10n.tr("strong_reminder.dismiss")) {
                    onDismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .controlSize(.large)
                .pointerCursor()
            }
            .padding(12)
        }
    }
}
