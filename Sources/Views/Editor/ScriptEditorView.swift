import SwiftUI

struct ScriptEditorView: View {
    @Binding var scriptBody: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $scriptBody)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.black.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.separator, lineWidth: 0.5)
                )

            Text(L10n.tr("editor.script.placeholder"))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
