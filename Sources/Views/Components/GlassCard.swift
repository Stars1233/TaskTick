import SwiftUI

/// A card component with glass material effect.
/// Uses liquid glass on macOS 26+, falls back to themed material on older versions.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    let content: Content

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background {
                if #available(macOS 26.0, *) {
                    // Glass only — no material underneath it. `.ultraThinMaterial`
                    // is itself an opaque-ish grey blur, and glass composited on
                    // top of it loses the translucency it exists for: the card
                    // reads as flat grey instead of glass. This showed up as
                    // "everything looks grey" once macOS 27 lightened the
                    // surrounding window chrome and the dull cards stood out.
                    Color.clear
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 12))
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.background)
                        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(.separator, lineWidth: 0.5)
                        )
                }
            }
    }
}
