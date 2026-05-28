import SwiftUI

/// Single-axis flow layout: children fill horizontally, wrap to the next line
/// when they run out of width. Used to lay out time-of-day chips in the task
/// editor. Sized for ~6 items on a 480pt-wide form.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6
    /// Horizontal alignment within the proposed width. `.trailing` right-pins
    /// each wrapped line; `.leading` (default) left-pins.
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var contentMaxLineWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if lineWidth + size.width > maxWidth && lineWidth > 0 {
                totalHeight += lineHeight + lineSpacing
                contentMaxLineWidth = max(contentMaxLineWidth, lineWidth - spacing)
                lineWidth = size.width + spacing
                lineHeight = size.height
            } else {
                lineWidth += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalHeight += lineHeight
        contentMaxLineWidth = max(contentMaxLineWidth, lineWidth - spacing)

        // When given a finite proposal, consume it fully so trailing-aligned
        // lines can pin to the right edge of the container; otherwise fall
        // back to the intrinsic content width.
        let width: CGFloat
        if let pw = proposal.width, pw.isFinite {
            width = pw
        } else {
            width = contentMaxLineWidth
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width

        // Group subview indices into lines based on wrap behavior, capturing
        // each subview's size once so the place step doesn't re-measure.
        var lines: [[(index: Int, size: CGSize)]] = [[]]
        var currentLineWidth: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if currentLineWidth + size.width > maxWidth && !lines[lines.count - 1].isEmpty {
                lines.append([(i, size)])
                currentLineWidth = size.width + spacing
            } else {
                lines[lines.count - 1].append((index: i, size: size))
                currentLineWidth += size.width + spacing
            }
        }

        var y: CGFloat = bounds.minY
        for line in lines where !line.isEmpty {
            let totalLineWidth = line.reduce(0) { $0 + $1.size.width }
                + CGFloat(max(line.count - 1, 0)) * spacing
            let lineHeight = line.map(\.size.height).max() ?? 0
            var x: CGFloat
            switch alignment {
            case .trailing:
                x = bounds.maxX - totalLineWidth
            case .center:
                x = bounds.midX - totalLineWidth / 2
            default:
                x = bounds.minX
            }
            for entry in line {
                // Vertically center each item within the line so items of
                // different heights (e.g. a 22pt button next to a 24pt
                // stepperField picker) share the same midline.
                let itemY = y + (lineHeight - entry.size.height) / 2
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: itemY),
                    proposal: ProposedViewSize(entry.size)
                )
                x += entry.size.width + spacing
            }
            y += lineHeight + lineSpacing
        }
    }
}
