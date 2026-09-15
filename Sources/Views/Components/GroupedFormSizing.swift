import SwiftUI

extension View {
    /// Gives a `Form(.grouped)` inside a sizing `TabView` a height floor, so the
    /// tab opens tall enough that its scroll view has nothing left to scroll.
    ///
    /// Both the Settings and the Task Editor windows are a `TabView` of grouped
    /// forms sized by `.fixedSize(vertical:)` → `.windowResizability(.contentSize)`.
    /// `Form(.grouped)` wraps its rows in a ScrollView, and on macOS 26+ the
    /// ideal height that scroll view reports back up the chain lands roughly
    /// 20pt short of the rows it actually contains. The window therefore opens
    /// ~20pt too small and the form stays permanently scrollable by that much —
    /// invisible at rest, because macOS overlay scrollers only draw while
    /// scrolling, but a stray two-finger swipe makes the scroller appear and
    /// the content twitch.
    ///
    /// `minHeight` lands *before* `fixedSize`, so the ideal height the chain
    /// measures becomes `max(minHeight, form's own ideal)` and the form is
    /// actually laid out at that height — which is what makes the scroll view's
    /// viewport grow. Adding padding or a safe-area inset instead does not work:
    /// those grow the container around the form while the form itself stays
    /// pinned to its short ideal, and the scroller survives.
    ///
    /// Values are per-tab and measured, in the same spirit as
    /// `SettingsView.windowWidth`: each one is that tab's content height as laid
    /// out on screen plus ~40pt of headroom, enough to absorb both the ideal-height
    /// shortfall and the modest reflow between `en` and `zh-Hans`. A tab whose
    /// content genuinely exceeds its floor still grows and still scrolls.
    func groupedFormSizing(minHeight: CGFloat) -> some View {
        frame(minHeight: minHeight)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
    }
}
