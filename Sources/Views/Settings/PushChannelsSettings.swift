import SwiftUI
import TaskTickCore

/// Live, observable view of the configured push channels (issue #51).
///
/// UserDefaults stays the single source of truth — this writes through on every
/// mutation and never caches a value the disk doesn't have. SwiftUI can't
/// observe UserDefaults directly, and a computed `Binding` reading it straight
/// would leave toggles showing stale state between re-renders.
@MainActor
final class PushChannelSettings: ObservableObject {

    static let shared = PushChannelSettings()

    @Published var channels: [PushChannel] {
        didSet { PushChannelStore.save(channels) }
    }

    private init() {
        channels = PushChannelStore.load()
    }

    /// Re-reads from disk. Cheap insurance for the one case the write-through
    /// can't cover: the launch-time Bark migration writes before this object
    /// exists.
    func reload() {
        let stored = PushChannelStore.load()
        guard stored != channels else { return }
        channels = stored
    }

    func makeChannel(kind: PushProviderKind) -> PushChannel {
        PushChannel(
            kind: kind,
            name: uniqueName(for: kind),
            // Gotify's own docs use 5 as the "normal" example; Bark and webhook
            // ignore the field entirely.
            priority: 5
        )
    }

    /// "Gotify", then "Gotify 2", … — two endpoints of the same kind have to be
    /// distinguishable in the task editor's channel list.
    private func uniqueName(for kind: PushProviderKind) -> String {
        let base = kind.displayName
        let taken = Set(channels.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}

// MARK: - Settings section

/// The "Push Channels" block in Settings ▸ General. Replaces the single Bark
/// URL field that predated issue #51.
struct PushChannelsSection: View {

    @ObservedObject private var settings = PushChannelSettings.shared
    @State private var editingChannelID: UUID?
    @State private var channelToDelete: PushChannel?

    var body: some View {
        Section {
            if settings.channels.isEmpty {
                Text(L10n.tr("settings.push.empty"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach($settings.channels) { $channel in
                    row(for: $channel)
                }
            }

            // The sheet and the delete dialog hang off this row, not off the
            // Section: a modifier applied to `Section` inside a `Form` wraps it
            // in ModifiedContent and Form stops rendering it as a section.
            HStack {
                Menu {
                    ForEach(PushProviderKind.allCases) { kind in
                        Button {
                            addChannel(kind: kind)
                        } label: {
                            Label(kind.displayName, systemImage: kind.symbolName)
                        }
                    }
                } label: {
                    Label(L10n.tr("settings.push.add"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .pointerCursor()

                Spacer()
            }
            .sheet(item: editingChannelBinding) { channel in
                PushChannelEditorSheet(channel: binding(for: channel.id))
            }
            .confirmationDialog(
                L10n.tr("settings.push.delete.confirm", channelToDelete?.displayName ?? ""),
                isPresented: Binding(get: { channelToDelete != nil }, set: { if !$0 { channelToDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button(L10n.tr("settings.push.delete"), role: .destructive) {
                    if let id = channelToDelete?.id {
                        settings.channels.removeAll { $0.id == id }
                    }
                    channelToDelete = nil
                }
                Button(L10n.tr("settings.push.cancel"), role: .cancel) { channelToDelete = nil }
            }
        } header: {
            Text(L10n.tr("settings.push"))
        } footer: {
            Text(L10n.tr("settings.push.hint"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func row(for channel: Binding<PushChannel>) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: channel.isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(L10n.tr("settings.push.channel.enabled"))

            Image(systemName: channel.wrappedValue.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.wrappedValue.displayName)
                    .lineLimit(1)
                // A channel that can't send says so here rather than at run
                // time, where the only trace would be a line in Console.
                if let error = channel.wrappedValue.validationError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else {
                    Text(channel.wrappedValue.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button(L10n.tr("settings.push.edit")) {
                editingChannelID = channel.wrappedValue.id
            }
            .pointerCursor()

            Button {
                channelToDelete = channel.wrappedValue
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .pointerCursor()
            .help(L10n.tr("settings.push.delete"))
        }
    }

    private func addChannel(kind: PushProviderKind) {
        let channel = settings.makeChannel(kind: kind)
        settings.channels.append(channel)
        editingChannelID = channel.id
    }

    /// `sheet(item:)` needs an Identifiable; the id alone is what we track so a
    /// live edit to the channel doesn't re-present the sheet.
    private var editingChannelBinding: Binding<PushChannel?> {
        Binding(
            get: {
                guard let id = editingChannelID else { return nil }
                return settings.channels.first { $0.id == id }
            },
            set: { if $0 == nil { editingChannelID = nil } }
        )
    }

    /// Binding straight into the stored array so edits persist as they're typed
    /// — and so a channel deleted underneath the sheet degrades to a harmless
    /// scratch value instead of trapping on a stale index.
    private func binding(for id: UUID) -> Binding<PushChannel> {
        Binding(
            get: { settings.channels.first { $0.id == id } ?? PushChannel(id: id) },
            set: { updated in
                guard let index = settings.channels.firstIndex(where: { $0.id == id }) else { return }
                settings.channels[index] = updated
            }
        )
    }
}

// MARK: - Channel editor

struct PushChannelEditorSheet: View {

    @Binding var channel: PushChannel
    @Environment(\.dismiss) private var dismiss

    @State private var isSendingTest = false
    @State private var testResult: TestResult?

    private struct TestResult: Identifiable {
        let id = UUID()
        let succeeded: Bool
        let message: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField(L10n.tr("settings.push.channel.name"), text: $channel.name)
                    Toggle(L10n.tr("settings.push.channel.enabled"), isOn: $channel.isEnabled)
                }

                switch channel.kind {
                case .bark: barkFields
                case .gotify: gotifyFields
                case .webhook: webhookFields
                case .wecomApp: wecomAppFields
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 8) {
                Button(L10n.tr("settings.push.test")) { sendTest() }
                    .disabled(!channel.isValid || isSendingTest)
                    .pointerCursor()

                if isSendingTest {
                    ProgressView().controlSize(.small)
                }

                if let error = channel.validationError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }

                Spacer()

                Button(L10n.tr("settings.push.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .pointerCursor()
            }
            .padding(12)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .alert(item: $testResult) { result in
            Alert(
                title: Text(result.succeeded
                            ? L10n.tr("settings.push.test.success")
                            : L10n.tr("settings.push.test.failed")),
                message: Text(result.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    // MARK: Per-provider fields

    private var barkFields: some View {
        Section {
            TextField(L10n.tr("settings.push.url"), text: $channel.serverURL,
                      prompt: Text("https://api.day.app/your_device_key"))
        } header: {
            Text(PushProviderKind.bark.displayName)
        } footer: {
            Text(L10n.tr("settings.push.bark.hint"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gotifyFields: some View {
        Section {
            TextField(L10n.tr("settings.push.url"), text: $channel.serverURL,
                      prompt: Text("https://push.example.com"))
            // App token, not a client token: Gotify rejects the latter on
            // POST /message with a 401 that reads like a typo'd URL.
            SecureField(L10n.tr("settings.push.gotify.token"), text: $channel.token)
            Picker(L10n.tr("settings.push.gotify.priority"), selection: $channel.priority) {
                ForEach(0...10, id: \.self) { Text("\($0)").tag($0) }
            }
        } header: {
            Text(PushProviderKind.gotify.displayName)
        } footer: {
            Text(L10n.tr("settings.push.gotify.hint"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var webhookFields: some View {
        Section {
            TextField(L10n.tr("settings.push.url"), text: $channel.serverURL,
                      prompt: Text("https://ntfy.sh/my-topic"))

            Picker(L10n.tr("settings.push.webhook.method"), selection: $channel.httpMethod) {
                ForEach(["POST", "PUT", "GET"], id: \.self) { Text($0).tag($0) }
            }

            TextField(L10n.tr("settings.push.webhook.content_type"), text: $channel.contentType,
                      prompt: Text("application/json"))

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("settings.push.webhook.headers"))
                TextEditor(text: $channel.headersJSON)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 44)
                    .scrollContentBackground(.hidden)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            }

            // Hidden for GET/HEAD: those carry their payload in the URL, so a
            // body field would just be a box the user fills in for nothing.
            if !["GET", "HEAD"].contains(channel.httpMethod.uppercased()) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("settings.push.webhook.body"))
                    TextEditor(text: $channel.bodyTemplate)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 88)
                        .scrollContentBackground(.hidden)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                }
            }
        } header: {
            Text(PushProviderKind.webhook.displayName)
        } footer: {
            Text(L10n.tr("settings.push.webhook.hint"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wecomAppFields: some View {
        Section {
            TextField(L10n.tr("settings.push.wecom.corp_id"), text: $channel.corpID,
                      prompt: Text("ww1234567890abcdef"))
            // App secret, not the 通讯录 secret: every 自建应用 has its own, and
            // the token minted from one app's secret can't send as another.
            SecureField(L10n.tr("settings.push.wecom.secret"), text: $channel.token)
            TextField(L10n.tr("settings.push.wecom.agent_id"), text: $channel.agentID,
                      prompt: Text("1000002"))
            TextField(L10n.tr("settings.push.wecom.to_user"), text: $channel.toUser,
                      prompt: Text(PushChannel.defaultWeComRecipient))
        } header: {
            Text(PushProviderKind.wecomApp.displayName)
        } footer: {
            Text(L10n.tr("settings.push.wecom.hint"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sendTest() {
        isSendingTest = true
        let target = channel
        Task {
            let result = await PushDispatcher.shared.sendTest(channel: target)
            isSendingTest = false
            switch result {
            case .success:
                testResult = TestResult(
                    succeeded: true,
                    message: L10n.tr("settings.push.test.success.message")
                )
            case .failure(let error):
                testResult = TestResult(
                    succeeded: false,
                    message: error.localizedDescription
                )
            }
        }
    }
}
