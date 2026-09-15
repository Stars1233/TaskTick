import SwiftUI

/// A capsule segmented control in the Liquid Glass idiom: one glass pill holds
/// the whole control, and the selected segment rides inside it on its own
/// capsule that slides between positions.
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
@available(macOS 26.0, *)
struct GlassSegmentedControl<Value: Hashable>: View {
    let options: [Value]
    let label: (Value) -> String
    @Binding var selection: Value

    /// Ties every segment's selected-capsule background to one geometry group so
    /// SwiftUI interpolates a single pill sliding across, instead of cross-fading
    /// one capsule out and another in.
    @Namespace private var pill

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
                                    .fill(.background.secondary)
                                    .matchedGeometryEffect(id: "selected", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .pointerCursor()
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }
}
