import SwiftUI
import AppKit

/// Proportions of TaskTick's mark, all as fractions of the dial's rendered
/// width so they hold at any point size.
enum BrandMarkMetrics {
    /// Badge diameter.
    static let badge: CGFloat = 0.42
    /// Glyph inside the badge.
    static let glyph: CGFloat = 0.29
    /// Clear ring punched around the badge, separating it from the dial.
    static let gap: CGFloat = 0.06
}

/// Draws TaskTick's mark: a solid clock face with a badge cut into its
/// bottom-right corner, holding a shell prompt when idle and a play triangle
/// while a task runs.
///
/// A solid dial rather than an outline, matching the app icon — its face is a
/// filled disc with white hands. The badge carries the state because the fill
/// is already spent on being on-brand: `›` means "ready to run something", `▶`
/// means "running right now". Both states keep the same silhouette and weight,
/// so the icon never jumps; only the small glyph in the corner changes.
///
/// No SF Symbol carries this pairing — `clock.badge.*` puts its badge on the
/// opposite corner and offers no prompt variant — so it is composited here.
///
/// **This is the single renderer.** The SwiftUI `BrandMark` and the menu bar
/// status item both go through it. They used to each draw their own version and
/// silently disagreed: the AppKit one sized the badge off the symbol's rendered
/// width while the SwiftUI one used the font's point size, and since a symbol
/// renders wider than its point size, the same 0.42 produced visibly different
/// badges. Sharing constants was not enough; they have to share the drawing.
@MainActor
enum BrandMarkRenderer {
    /// Cache keyed by the only two things that change the drawing. Views ask for
    /// this on every body evaluation, and compositing four symbol draws each
    /// time would be wasteful for an image with a handful of variants.
    private static var cache: [String: NSImage] = [:]

    /// A template image — callers tint it (SwiftUI via `foregroundStyle`, the
    /// status item automatically from the menu bar's appearance).
    static func image(pointSize: CGFloat, running: Bool) -> NSImage {
        let key = "\(pointSize)-\(running)"
        if let cached = cache[key] { return cached }

        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        guard let dial = NSImage(systemSymbolName: "clock.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return NSImage() }

        let size = dial.size
        let diameter = size.width * BrandMarkMetrics.badge
        let badge = NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)
        let gap = max(1, size.width * BrandMarkMetrics.gap)

        // The play triangle reads heavier than the chevron at equal size, so it
        // is nudged down to keep the two states optically matched.
        let glyphName = running ? "play.fill" : "chevron.right"
        let glyphScale = BrandMarkMetrics.glyph * (running ? 0.92 : 1)
        let glyph = NSImage(systemSymbolName: glyphName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: pointSize * glyphScale, weight: .bold)
            )

        let composed = NSImage(size: size)
        composed.lockFocus()
        dial.draw(in: NSRect(origin: .zero, size: size))

        // `compositingOperation` governs path fills; it is ignored by
        // `NSImage.draw(in:)`, which needs the operation passed explicitly.
        NSGraphicsContext.current?.compositingOperation = .clear
        NSBezierPath(ovalIn: badge.insetBy(dx: -gap, dy: -gap)).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.black.setFill()
        NSBezierPath(ovalIn: badge).fill()
        if let glyph {
            let rect = NSRect(x: badge.midX - glyph.size.width / 2,
                              y: badge.midY - glyph.size.height / 2,
                              width: glyph.size.width,
                              height: glyph.size.height)
            glyph.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1.0)
        }
        composed.unlockFocus()

        let result = anchoredOnCanvas(composed, canvasSize: size)
        cache[key] = result
        return result
    }

    /// Pin the four corners of the canvas with near-invisible (alpha 1/100)
    /// pixels so AppKit treats the full canvas as the image's bounding box.
    /// Without this, status-item layout uses the visible-content bbox of each
    /// NSImage, which differs between the idle and running badges — making the
    /// menu bar icon visibly drift sideways when a task starts.
    private static func anchoredOnCanvas(_ image: NSImage, canvasSize: NSSize) -> NSImage {
        let anchored = NSImage(size: canvasSize)
        anchored.lockFocus()
        NSColor(white: 0, alpha: 0.01).setFill()
        NSRect(x: 0, y: 0, width: 1, height: 1).fill()
        NSRect(x: canvasSize.width - 1, y: 0, width: 1, height: 1).fill()
        NSRect(x: 0, y: canvasSize.height - 1, width: 1, height: 1).fill()
        NSRect(x: canvasSize.width - 1, y: canvasSize.height - 1, width: 1, height: 1).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        anchored.unlockFocus()
        anchored.isTemplate = true
        return anchored
    }
}

/// TaskTick's mark for in-app use, tinted.
///
/// Only for places that stand for the app itself — the menu bar popover's
/// header, the quick launcher. Clocks that mean a *time* (timeouts, next-run,
/// the editor's time field) stay ordinary SF Symbols.
struct BrandMark: View {
    /// Point size of the dial; everything else scales from the rendered glyph.
    var size: CGFloat = 14
    var tint: Color = .accentColor
    var running: Bool = false

    var body: some View {
        Image(nsImage: BrandMarkRenderer.image(pointSize: size, running: running))
            .renderingMode(.template)
            .foregroundStyle(tint)
    }
}
