import AppKit

/// Legacy entry point for opening the SwiftUI `Settings { }` scene from
/// non-Scene contexts (quick launcher NSPanel) where the `openSettings`
/// environment action isn't available.
///
/// ⚠️ Inside a SwiftUI scene, use `@Environment(\.openSettings)` instead:
/// on macOS 14+ the `showSettingsWindow:` selector can report success
/// without actually creating the window (observed from the menu bar panel).
@MainActor
enum SettingsWindowOpener {
    static func open() {
        NSApp.setActivationPolicy(.regular)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            // Pre-macOS 13 selector. Harmless when targeting 14+ — kept as a
            // belt-and-suspenders fallback in case the new selector silently
            // fails on a future regression.
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
