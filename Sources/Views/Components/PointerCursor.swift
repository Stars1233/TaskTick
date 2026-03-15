import SwiftUI
import AppKit

/// Adds a pointing hand cursor on hover for any view.
struct PointerCursorModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

extension View {
    /// Makes the cursor a pointing hand when hovering over this view.
    func pointerCursor() -> some View {
        modifier(PointerCursorModifier())
    }
}
