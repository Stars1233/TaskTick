import SwiftUI

struct CronEditorView: View {
    @Binding var expression: String
    @State private var isCustom = false

    static let presets: [(key: String, value: String)] = [
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
            Picker(L10n.tr("cron.preset"), selection: $expression) {
                ForEach(Self.presets, id: \.value) { preset in
                    Text(L10n.tr(preset.key)).tag(preset.value)
                }
                Divider()
                Text(L10n.tr("cron.custom")).tag("__custom__")
            }
            .onChange(of: expression) { _, newValue in
                isCustom = (newValue == "__custom__")
                if isCustom {
                    expression = "* * * * *"
                }
            }

            if isCustom || !Self.presets.contains(where: { $0.value == expression }) {
                TextField(
                    L10n.tr("cron.expression.placeholder"),
                    text: $expression
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
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
