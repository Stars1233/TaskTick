import SwiftUI
import TaskTickCore

struct CronEditorView: View {
    @Binding var expression: String
    /// Picker state, decoupled from `expression`: driving the picker off the
    /// expression itself made "Custom" unselectable — its onChange rewrote the
    /// expression to a value that collided with the "Every Minute" preset and
    /// the selection snapped away. Custom keeps whatever expression is current
    /// and edits it in the text field.
    @State private var selection = CronEditorView.customTag

    static let customTag = "__custom__"

    static let presets: [(key: String, value: String)] = [
        ("cron.every_10_seconds", "*/10 * * * * *"),
        ("cron.every_30_seconds", "*/30 * * * * *"),
        ("cron.every_minute", "* * * * *"),
        ("cron.every_5_minutes", "*/5 * * * *"),
        ("cron.every_15_minutes", "*/15 * * * *"),
        ("cron.every_30_minutes", "*/30 * * * *"),
        ("cron.every_hour", "0 * * * *"),
        ("cron.daily_midnight", "0 0 * * *"),
        ("cron.daily_8am", "0 8 * * *"),
        ("cron.weekly_monday", "0 9 * * 1"),
        ("cron.monthly_first", "0 0 1 * *"),
    ]

    var nextFireDescription: String {
        guard let cron = try? CronExpression(parsing: expression),
              let nextDate = cron.nextFireDate() else {
            return L10n.tr("cron.cannot_compute")
        }
        return nextDate.formatted(date: .abbreviated, time: .standard)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.tr("cron.preset"), selection: $selection) {
                ForEach(Self.presets, id: \.value) { preset in
                    Text(L10n.tr(preset.key)).tag(preset.value)
                }
                Divider()
                Text(L10n.tr("cron.custom")).tag(Self.customTag)
            }
            .onChange(of: selection) { _, newValue in
                if newValue != Self.customTag {
                    expression = newValue
                }
            }
            .onAppear {
                selection = Self.presets.contains(where: { $0.value == expression })
                    ? expression
                    : Self.customTag
            }

            if selection == Self.customTag {
                TextField(
                    L10n.tr("cron.expression.placeholder"),
                    text: $expression
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

                Text(L10n.tr("cron.fields.hint"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Next fire date
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(L10n.tr("cron.next_run", nextFireDescription))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
    }
}
