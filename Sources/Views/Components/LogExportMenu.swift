import AppKit
import SwiftUI
import TaskTickCore

/// AppKit pull-down used for the log "Export" toolbar control.
///
/// Why not a SwiftUI `Menu`? A SwiftUI `Menu` placed at `.primaryAction`
/// inherits the default-action (Return) keyboard shortcut, which SwiftUI then
/// renders as a stray ↵ glyph next to every menu item — with no API to suppress
/// it while keeping the control in the trailing toolbar slot. An `NSMenu`'s
/// items carry no key equivalent, so this control looks and behaves identically
/// (icon + "Export" title + chevron, click to open) but without the ↵.
struct LogExportMenu: NSViewRepresentable {
    let title: String
    let selectedEnabled: Bool
    let allEnabled: Bool
    let onExportSelected: () -> Void
    let onExportAll: () -> Void

    // Tags identify the menu items across rebuilds / state updates.
    private enum Tag {
        static let titleLabel = 0
        static let exportSelected = 1
        static let exportAll = 2
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .toolbar
        button.imagePosition = .imageLeading
        button.toolTip = title

        let menu = NSMenu()
        menu.autoenablesItems = false   // we drive isEnabled ourselves

        // Item 0 is the always-visible button label (icon + title) in pull-down mode.
        let label = NSMenuItem()
        label.tag = Tag.titleLabel
        label.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: title)
        menu.addItem(label)

        let selected = NSMenuItem(title: L10n.tr("log.export.selected"),
                                  action: #selector(Coordinator.exportSelected), keyEquivalent: "")
        selected.tag = Tag.exportSelected
        selected.target = context.coordinator
        menu.addItem(selected)

        let all = NSMenuItem(title: L10n.tr("log.export.all"),
                             action: #selector(Coordinator.exportAll), keyEquivalent: "")
        all.tag = Tag.exportAll
        all.target = context.coordinator
        menu.addItem(all)

        button.menu = menu
        button.sizeToFit()
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onExportSelected = onExportSelected
        context.coordinator.onExportAll = onExportAll
        guard let menu = button.menu else { return }
        menu.item(withTag: Tag.titleLabel)?.title = title
        menu.item(withTag: Tag.exportSelected)?.isEnabled = selectedEnabled
        menu.item(withTag: Tag.exportAll)?.isEnabled = allEnabled
    }

    final class Coordinator: NSObject {
        var onExportSelected: () -> Void = {}
        var onExportAll: () -> Void = {}

        @objc func exportSelected() { onExportSelected() }
        @objc func exportAll() { onExportAll() }
    }
}
