import AppKit
import SwiftData
import SwiftUI

/// Custom NSPanel that intercepts keyboard shortcuts the OS would otherwise
/// drop on a borderless-style panel: Escape (cancelOperation) and ⌘W
/// (performClose) both route through the dismiss callback.
///
/// The shadow trick that drives this whole class: mixing `.titled` into the
/// styleMask is what gets us the standard macOS window shadow at the
/// WindowServer level. Borderless-only panels and borderless-only windows
/// alike get the compact "popup" shadow, which looked visibly thinner than
/// every other window in the app. The matching `.borderless` flag plus
/// `titleVisibility = .hidden` + `titlebarAppearsTransparent = true` keep
/// the titlebar invisible, and `.fullSizeContentView` lets SwiftUI paint all
/// the way to the panel edge. NSPanel (not NSWindow) is preserved so the
/// `.nonactivatingPanel` flag is available — we need that to receive key
/// focus without activating the app and stealing foreground from whatever
/// the user was doing.
final class QuickLauncherPanel: NSPanel {
    var onDismiss: (() -> Void)?

    /// Borderless-styled panels default to non-key, which would prevent the
    /// search field from receiving keystrokes. Force-enable both so the
    /// embedded TextField can take focus and the panel reacts to shortcuts.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func performClose(_ sender: Any?) {
        onDismiss?()
    }
}

/// Transparent cover for the otherwise-invisible titlebar region. The system
/// would normally swallow clicks/drags in the titlebar zone before they
/// reach SwiftUI; this view absorbs them and routes them through
/// `performDrag` so `isMovableByWindowBackground` still works there.
private final class DragOnlyTitlebarView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// Owns the floating panel that hosts `QuickLauncherView`. Toggles visibility
/// in response to the global hotkey and dismisses on focus loss / Escape.
@MainActor
final class QuickLauncherController: NSObject, NSWindowDelegate {

    static let shared = QuickLauncherController()

    private var panel: QuickLauncherPanel?
    /// Retains the current SwiftUI host controller (recreated on every show()
    /// so `@Query` re-fetches and `@State` resets). We assign `host.view` to
    /// a manually-built wrapper NSView rather than going through
    /// `panel.contentViewController` — the controller path wraps host.view
    /// in a system-managed hierarchy that prevents CALayer cornerRadius from
    /// clipping the bottom corners. The wrapper holds host.view as a subview,
    /// but nothing in the AppKit tree retains the controller object itself,
    /// so we keep a strong reference here.
    private var hostController: NSViewController?
    private var modelContainer: ModelContainer?
    /// Most recent time the panel actually became key. Used to ignore the
    /// transient resign-key that fires on cold start when the system briefly
    /// shuffles focus during app activation — without this guard, the panel
    /// flashes open and immediately hides itself.
    private var lastBecameKeyAt: Date?

    /// Stash the container at app boot so `toggle()` can wire SwiftData into the
    /// panel without depending on whoever triggered the hotkey.
    func configure(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Show if hidden, hide if shown. Called from the global hotkey handler.
    func toggle() {
        if let panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let modelContainer else { return }

        let panel = panel ?? makePanel()
        self.panel = panel

        // Refresh the SwiftUI host every time so the @Query inside re-fetches
        // and the search field's @State resets to empty/index-0. Without this,
        // the panel remembers the previous query and selection.
        let host = NSHostingController(rootView:
            QuickLauncherView(onDismiss: { [weak self] in self?.hide() })
                .modelContainer(modelContainer)
        )
        host.sizingOptions = .preferredContentSize
        // Detach the SwiftUI host from the panel's titlebar safe area.
        // `.titled` gives the panel a 28pt top safe area for the titlebar
        // (even when titlebar is transparent + hidden). SwiftUI's
        // `.ignoresSafeArea()` modifier renders *content* past the safe
        // area but still reports an intrinsic that *includes* it — so the
        // panel ends up `content + 28pt` tall while content draws only
        // `content` pt from the top, leaving 28pt of empty translucent
        // space at the bottom (the visible gap below the footer hints).
        // `safeAreaRegions = []` tells the host to ignore the inherited
        // safe area entirely, so SwiftUI's intrinsic == actual content
        // and panel.height matches with no leftover. Available macOS 13.3+.
        host.safeAreaRegions = []
        hostController = host

        // Pin host.view's width and read its preferred height BEFORE we
        // attach it to the wrapper. Once host.view is constrained to fill
        // the wrapper top-to-bottom, `fittingSize` returns the constraint-
        // clamped height instead of SwiftUI's natural intrinsic — and the
        // panel ends up sized to that clamp, leaving empty space below
        // the footer hints. Layout-then-fittingSize on the detached view
        // gives SwiftUI's true preferred size at the panel width.
        // Initial size guess. SwiftUI's true intrinsic at this width isn't
        // fully reliable until host.view is in the window hierarchy and has
        // laid out — `fittingSize` here often under-reports (e.g. 261 vs
        // the actual 293 the live ScrollView wants). We feed this as an
        // initial frame anyway; Auto Layout between host.view's intrinsic
        // content size (priority 750) and the required wrapper-fill
        // constraints will push the panel up to the true intrinsic right
        // after `setFrame`, while the panel is still at `alphaValue = 0`
        // (the 80ms alpha-in delay covers the resize). See settled-state
        // verification in commit history.
        host.view.setFrameSize(NSSize(width: panelWidth, height: 1))
        host.view.layoutSubtreeIfNeeded()
        let targetHeight = max(host.view.fittingSize.height, 200)

        // Manual contentView wrapper, mirroring PasteMemo's QuickPanel:
        // 1. Explicit initial frame so the layer's masksToBounds clip is
        //    correct on the very first paint.
        // 2. NSVisualEffectView as background. The previous opaque
        //    `Color.windowBackgroundColor` made NSThemeFrame (the system
        //    root view that `.titled` brings along for the standard
        //    shadow) poke through the wrapper's rounded corner cut-outs
        //    as visible square corners at the bottom. NSVisualEffectView
        //    with `.behindWindow` blending paints no opaque pixels of its
        //    own — the cut-outs stay genuinely transparent so the rounded
        //    shape shows all the way around. Also matches the Spotlight /
        //    Raycast visual idiom for hotkey-summoned launchers.
        // 3. `.continuous` corner curve = Apple squircle.
        let wrapper = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: targetHeight))
        wrapper.wantsLayer = true
        wrapper.layer?.cornerRadius = 12
        wrapper.layer?.cornerCurve = .continuous
        wrapper.layer?.masksToBounds = true

        let visualEffect = NSVisualEffectView(frame: wrapper.bounds)
        visualEffect.material = .headerView
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.autoresizingMask = [.width, .height]
        wrapper.addSubview(visualEffect)

        host.view.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        ])
        wrapper.layoutSubtreeIfNeeded()
        panel.contentView = wrapper

        // Use `setFrame` (full window frame) rather than `setContentSize`.
        // With `.titled + .fullSizeContentView`, `setContentSize(w, h)` sets
        // the contentRect to (w, h) — but the contentView visually extends
        // across the titlebar zone, so it actually ends up `h +
        // titlebarHeight` tall. SwiftUI renders at the top, the extra
        // titlebar-height worth of contentView at the bottom shows up as
        // empty translucent space below the footer hints. Sizing the
        // window frame to the intrinsic height directly makes contentView
        // match exactly.
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let topY = visible.maxY - 150
        let leftX = visible.midX - panelWidth / 2
        let originY = topY - targetHeight
        panel.setFrame(NSRect(x: leftX, y: originY, width: panelWidth, height: targetHeight), display: true)

        // Alpha-in transition masks the first-paint flash described in the
        // prewarm comment below. `orderFrontRegardless` + `makeKey` (rather
        // than `makeKeyAndOrderFront`) is the canonical sequence for
        // `.nonactivatingPanel`s — the panel becomes the key window without
        // forcing the app to activate, so the user's previous foreground
        // app keeps its menu bar and Dock state.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            panel.alphaValue = 1.0
        }
    }

    /// Forces `CursorUIViewService` to spawn during app launch by briefly
    /// focusing an offscreen NSTextField. The XPC service is responsible
    /// for cursor / IME / autofill UI and its first-spawn latency is what
    /// causes the "下拉白卡片" flash when our search field gains focus.
    /// Calling this once at launch guarantees the service is warm long
    /// before the user can press the global hotkey.
    func prewarmCursorUI() {
        let window = NSPanel(
            contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.hasShadow = false
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        container.addSubview(field)
        window.contentView = container
        window.orderFrontRegardless()
        window.makeFirstResponder(field)
        // Hold long enough for the XPC service to fully initialize, then
        // tear the warmer down. 600ms is conservative; tested locally the
        // service is hot at ~300ms but slow machines need more headroom.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            window.orderOut(nil)
            // `window` is a local — once this closure ends and the panel is
            // out of the screen, ARC will release it.
        }
    }

    private var panelWidth: CGFloat { QuickLauncherView.cardWidth }

    func hide() {
        lastBecameKeyAt = nil
        panel?.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.lastBecameKeyAt = Date()
        }
    }

    /// Auto-dismiss when the user clicks outside the panel — classic Spotlight
    /// behavior. Without this the panel sticks around invisibly on top of
    /// whatever the user clicks next.
    ///
    /// On cold start (and sometimes when QL is summoned while another app is
    /// foreground), the focus chain shuffles for a few hundred ms after the
    /// panel first becomes key — the panel resigns key very briefly and the
    /// dismiss-on-resign would fire, hiding the panel just after the user
    /// summoned it. The 300ms grace period filters those transient events
    /// without interfering with deliberate clicks-outside (which only happen
    /// well after the user has had time to see the panel anyway).
    nonisolated func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let last = self.lastBecameKeyAt, Date().timeIntervalSince(last) < 0.3 {
                return
            }
            self.hide()
        }
    }

    // MARK: - Setup

    private func makePanel() -> QuickLauncherPanel {
        // The styleMask cocktail: `.titled` is the magic flag that opts the
        // panel into the standard NSWindow shadow at the WindowServer level
        // (borderless-only panels get the smaller popup shadow that looked
        // visibly thinner than every other window). `.borderless` and the
        // `titleVisibility`/`titlebarAppearsTransparent`/standard-button-
        // hidden combo hide the titlebar visually. `.fullSizeContentView`
        // lets SwiftUI paint across the titlebar zone. `.nonactivatingPanel`
        // (NSPanel-only) lets the panel become key without activating the
        // app, so we don't steal the previous app's foreground state.
        let panel = QuickLauncherPanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 200),
            styleMask: [.nonactivatingPanel, .titled, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Kill AppKit's default window-appearing animation. Without this,
        // makeKeyAndOrderFront pops the panel in with a scale animation that
        // renders one frame using the panel's default (white) background
        // before SwiftUI's content paints — visible as a "下拉白卡片"
        // ghost flash beneath the search bar. We do our own alpha 0→1
        // transition in show(), so AppKit's animation is pure liability.
        panel.animationBehavior = .none

        // Hide the system titlebar that came along with `.titled`. The flag
        // is in the styleMask purely for the shadow; visually we want a
        // clean borderless surface.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        // Cover the (now invisible) titlebar zone so clicks/drags there go
        // through `isMovableByWindowBackground` instead of being eaten by
        // the system's titlebar handler. Without this, drags landing in
        // the top few pixels of the search-bar area would silently do
        // nothing.
        let titlebarCover = NSTitlebarAccessoryViewController()
        titlebarCover.layoutAttribute = .top
        let coverView = DragOnlyTitlebarView(frame: NSRect(x: 0, y: 0, width: 0, height: 1))
        coverView.autoresizingMask = [.width]
        titlebarCover.view = coverView
        panel.addTitlebarAccessoryViewController(titlebarCover)

        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.hide() }

        // Offscreen prewarm: paint the NSThemeFrame once before the user
        // ever sees the panel. `.titled` brings NSThemeFrame, which has a
        // well-known quirk of ignoring `alphaValue` on its very first paint
        // — without this dummy reveal at (-10_000, -10_000), the first
        // real summon would briefly flash an undecorated default-background
        // rectangle alongside the SwiftUI content. PasteMemo's QuickPanel
        // uses the same trick.
        panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        panel.orderOut(nil)
        return panel
    }

}
