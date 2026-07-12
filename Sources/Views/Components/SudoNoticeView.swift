import SwiftUI
import TaskTickCore

/// An orange banner shown when a failed run's stderr indicates sudo aborted
/// because there was no terminal to prompt for a password (issue #40).
/// Explains why and points at the passwordless-sudo (NOPASSWD) fix.
struct SudoNoticeView: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "terminal")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("log.detail.sudo_notice"))
                Text(L10n.tr("log.detail.sudo_notice_fix"))
                    .opacity(0.85)
            }
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
