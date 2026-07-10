import SwiftUI
import TaskTickCore

/// An orange banner explaining that a run was killed by the task timeout.
/// Shown in log detail views when a log's status is `.timeout`.
struct TimeoutNoticeView: View {
    /// The task's current timeout setting. The log doesn't store the value
    /// that was in effect at run time, so this may differ for old logs if
    /// the user has since changed the setting.
    let timeoutSeconds: Int?

    private var message: String {
        if let seconds = timeoutSeconds, seconds > 0 {
            L10n.tr("log.detail.timeout_notice", seconds)
        } else {
            L10n.tr("log.detail.timeout_notice_generic")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.badge.exclamationmark")
            Text(message)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.25), lineWidth: 0.5)
        )
    }
}
