import SwiftUI
import SwiftData

struct CrontabImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [CrontabImporter.CrontabEntry] = []
    @State private var selectedEntries: Set<String> = []
    @State private var isLoading = true
    @State private var importCompleted = false
    @State private var importedCount = 0
    @State private var showingCommentConfirm = false
    @State private var importedEntries: [CrontabImporter.CrontabEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("crontab.import.title"))
                        .font(.headline)
                    Text(L10n.tr("crontab.import.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()

            Divider()

            if isLoading {
                Spacer()
                ProgressView()
                    .padding()
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                ContentUnavailableView(
                    L10n.tr("crontab.import.empty"),
                    systemImage: "tray",
                    description: Text(L10n.tr("crontab.import.empty_description"))
                )
                Spacer()
            } else if importCompleted {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text(L10n.tr("crontab.import.success", importedCount))
                        .font(.headline)
                }
                Spacer()
            } else {
                // Entry list
                List(entries, id: \.originalLine, selection: $selectedEntries) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.command)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Image(systemName: "clock")
                                .font(.caption2)
                            Text(entry.cronExpression)
                                .font(.system(.caption, design: .monospaced))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(entry.originalLine)
                }
            }

            Divider()

            // Actions
            HStack {
                if !importCompleted {
                    Button(L10n.tr("editor.cancel")) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .pointerCursor()
                    Spacer()
                    if !entries.isEmpty {
                        Button(L10n.tr("crontab.import.select_all")) {
                            selectedEntries = Set(entries.map(\.originalLine))
                        }
                        .pointerCursor()

                        Button(L10n.tr("crontab.import.action")) {
                            performImport()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedEntries.isEmpty)
                        .pointerCursor()
                    }
                } else {
                    Spacer()
                    Button(L10n.tr("crontab.import.done")) { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .pointerCursor()
                }
            }
            .padding()
        }
        .frame(width: 520, height: 420)
        .onAppear { loadCrontab() }
        .alert(L10n.tr("crontab.comment.title"), isPresented: $showingCommentConfirm) {
            Button(L10n.tr("crontab.comment.yes"), role: .destructive) {
                _ = CrontabImporter.commentOutEntries(importedEntries)
            }
            Button(L10n.tr("crontab.comment.no"), role: .cancel) {}
        } message: {
            Text(L10n.tr("crontab.comment.message"))
        }
    }

    private func loadCrontab() {
        entries = CrontabImporter.readCrontab()
        selectedEntries = Set(entries.map(\.originalLine))
        isLoading = false
    }

    private func performImport() {
        let selected = entries.filter { selectedEntries.contains($0.originalLine) }
        do {
            importedCount = try CrontabImporter.importEntries(selected, into: modelContext)
        } catch {
            presentErrorAlert(titleKey: "error.import_failed.title",
                              messageKey: "error.import_save_failed",
                              error: error)
            return
        }
        importedEntries = selected
        TaskScheduler.shared.rebuildSchedule()

        withAnimation {
            importCompleted = true
        }

        // After a short delay, ask about commenting out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showingCommentConfirm = true
        }
    }
}
