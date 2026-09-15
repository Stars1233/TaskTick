import SwiftUI

/// A capsule segmented control in the Liquid Glass idiom: a glass trough holding
/// the segments, with the selected one riding inside it on a pill of its own.
///
/// `.pickerStyle(.segmented)` still draws the pre-26 bordered box with divider
/// bars between segments. Next to macOS 26+ window chrome — where the toolbar,
/// the search field and the sidebar are all capsules — that square box reads as
/// a foreign object, which is exactly how it looked once macOS 27 lightened
/// everything around it.
///
/// macOS 26+ only. Callers keep `.pickerStyle(.segmented)` as the fallback:
/// `glassEffect` doesn't exist on 14/15, and the bordered segmented control is
/// the native look there anyway.
///
/// ## Why the pill is a filled shape and not a `glassEffect`
///
/// UIKit's Liquid Glass lenses: drag a selected tab across an iOS or Mac
/// Catalyst tab bar and the glass visibly magnifies and disperses the labels
/// underneath it, like a droplet. AppKit's is a different implementation of the
/// same design language and does not do that — `Glass.interactive()` here
/// produces no refraction. Building the pill out of `glassEffect` +
/// `glassEffectID` to chase that effect was tried and gave up two things for
/// nothing: the morph animation fought the selection animation and made
/// dragging stutter, and the translucent pill lost contrast against the trough.
///
/// So: filled pill, `matchedGeometryEffect` for the slide, and an explicit
/// grow-on-drag for the "picked it up" feedback. That last part is the honest
/// approximation — a size change, not lensing. Revisit if AppKit ever ships the
/// refraction.
@available(macOS 26.0, *)
struct GlassSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    /// Ties every segment's selected-capsule background to one geometry group so
    /// SwiftUI interpolates a single pill sliding across, instead of cross-fading
    /// one capsule out and another in.
    @Namespace private var pill

    /// Measured on screen, for turning a drag's x into a segment index.
    @State private var controlWidth: CGFloat = 0

    /// True while a drag is in flight. `@GestureState` rather than `@State` so
    /// it resets itself when the gesture ends — including the cases that never
    /// deliver `onEnded`, like the pointer leaving the window mid-drag, where a
    /// manual flag would stay stuck on and leave the pill permanently enlarged.
    @GestureState private var isDragging = false

    @Environment(\.colorScheme) private var colorScheme

    /// Fill for the selected segment.
    ///
    /// What the eye judges is the *ratio* between the pill and the glass under
    /// it, not the absolute difference. This control floats on an already-light
    /// sidebar material (~0.18 luminance in dark mode), so a fill that looks
    /// bright in isolation still lands at only ~1.6× the trough and reads as
    /// merged. Tuned so the pill sits near 2× the trough, matching the
    /// separation that tab bars on a black background get for free.
    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.34) : Color.white
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    Text(label(option))
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(selectedFill)
                                    // Glass has a soft edge; the pill needs a
                                    // hard one or the two blur together at the
                                    // boundary however far apart their fills
                                    // are. A hairline highlight above and a
                                    // shadow below also give it somewhere to
                                    // sit — it reads as raised rather than as
                                    // a lighter patch of the same surface.
                                    .overlay(
                                        Capsule().strokeBorder(
                                            .white.opacity(colorScheme == .dark ? 0.16 : 0.9),
                                            lineWidth: 0.5
                                        )
                                    )
                                    .shadow(color: .black.opacity(shadowOpacity),
                                            radius: isDragging ? 6 : 3,
                                            y: isDragging ? 2 : 1)
                                    .matchedGeometryEffect(id: "selected", in: pill)
                                    // Lifts off the trough while being dragged.
                                    // 1.07 is about as far as it can go: the
                                    // trough only has `segmentRowInset` of room
                                    // around the pill, and past that the pill
                                    // clips against the capsule's edge.
                                    .scaleEffect(isDragging ? 1.07 : 1)
                                    .animation(.spring(response: 0.22, dampingFraction: 0.68),
                                               value: isDragging)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(segmentRowInset)
        .glassEffect(.regular, in: .capsule)
        // `onGeometryChange` rather than a GeometryReader in a background: the
        // background reader stopped reporting when this view was briefly nested
        // in a GlassEffectContainer, which left the width at 0 and silently
        // disabled the drag — the handler bails when it can't size a slot.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            controlWidth = newWidth
        }
        .simultaneousGesture(dragToSelect)
    }

    private var shadowOpacity: Double {
        if colorScheme == .dark { return isDragging ? 0.55 : 0.4 }
        return isDragging ? 0.26 : 0.16
    }

    /// Press-and-slide selection, the way `UISegmentedControl` and AppKit's
    /// `NSSegmentedControl` both behave: hold anywhere on the control and drag
    /// sideways, and the selection follows the pointer instead of requiring a
    /// separate click per segment.
    ///
    /// `minimumDistance: 4` keeps this out of the Buttons' way — a plain click
    /// never travels that far, so it is still the Button that handles taps and
    /// keeps its keyboard and accessibility behaviour. Only once the pointer
    /// actually moves does this take over. `simultaneousGesture` rather than
    /// `gesture` for the same reason: it must not replace the Buttons.
    private var dragToSelect: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($isDragging) { _, state, _ in state = true }
            .onChanged { value in
                // Segments are equal width (each is `maxWidth: .infinity`
                // inside an HStack), so the index is just which slot the x
                // falls into, measured from inside the capsule's inset.
                let row = controlWidth - segmentRowInset * 2
                guard row > 0, !options.isEmpty else { return }
                let slot = row / CGFloat(options.count)
                let index = Int((value.location.x - segmentRowInset) / slot)
                let target = options[min(max(index, 0), options.count - 1)]
                guard target != selection else { return }
                withAnimation(.snappy(duration: 0.25)) { selection = target }
            }
    }
}

/// Inset between the glass trough's edge and the segment row.
///
/// File scope rather than a `static let` on the view: `GlassSegmentedControl`
/// is generic, and Swift does not allow static stored properties on generic
/// types.
private let segmentRowInset: CGFloat = 3
