import AppKit
import SwiftUI

/// NSTextView-backed log viewer. SwiftUI's `Text(longString)` rebuilds layout
/// for the entire string on every update — for 500KB of monospaced live log
/// that's 50ms+ per flush and pegs the main thread. NSTextView's TextKit
/// fragmented layout only resolves visible glyphs, so even multi-MB content
/// stays interactive.
///
/// Behavior:
/// - Append-only updates (the common live-streaming case) diff and only
///   append new bytes, avoiding any full re-layout.
/// - Auto-scrolls to the bottom only when the user was already at the bottom —
///   pin-to-bottom is what they want while watching live output, but if they
///   scrolled up to inspect, we don't yank them back.
struct LogTextView: NSViewRepresentable {
    let text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 12, weight: .regular)
    var textColor: NSColor = .labelColor

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let tv = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.allowsUndo = false
        tv.font = font
        tv.textColor = textColor
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 10, height: 10)
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        // Wrap to view width; never force a horizontal scroller.
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )

        // Initial fill
        tv.string = text
        DispatchQueue.main.async {
            scrollToBottom(scrollView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        let current = tv.string
        if current == text { return }

        let wasAtBottom = isAtBottom(scrollView)

        if text.hasPrefix(current) && !current.isEmpty {
            // Append-only path — the live-streaming hot case. Insert only the
            // delta into textStorage; TextKit incrementally lays out the new
            // bytes instead of re-flowing the whole document.
            let delta = String(text.dropFirst(current.count))
            if !delta.isEmpty, let storage = tv.textStorage {
                storage.append(NSAttributedString(
                    string: delta,
                    attributes: [
                        .font: font,
                        .foregroundColor: textColor
                    ]
                ))
            }
        } else {
            // Buffer was reset or the prefix changed (e.g. line-cap trimmed
            // the oldest entries). Full replace — rare path.
            tv.string = text
        }

        if wasAtBottom {
            scrollToBottom(scrollView)
        }
    }

    private func isAtBottom(_ scrollView: NSScrollView) -> Bool {
        let clipView = scrollView.contentView
        let docHeight = clipView.documentRect.height
        let visibleBottom = clipView.bounds.origin.y + clipView.bounds.height
        // 40pt threshold — if the viewport is within 40pt of the bottom we
        // consider it "following live output" and keep scrolling.
        return docHeight - visibleBottom < 40
    }

    private func scrollToBottom(_ scrollView: NSScrollView) {
        guard let tv = scrollView.documentView as? NSTextView else { return }
        let length = (tv.string as NSString).length
        tv.scrollRangeToVisible(NSRange(location: length, length: 0))
    }
}
