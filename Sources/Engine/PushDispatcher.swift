import CryptoKit
import Foundation
import TaskTickCore

/// Sends task-completion pushes to every channel a task subscribes to.
///
/// Architecture mirrors `NotificationManager`: one shared sender, fire-and-forget
/// from `ScriptExecutor`. Channels are configured app-wide in Settings; each
/// task opts in via `ScheduledTask.pushEnabled` and optionally narrows the set
/// with `pushChannelIDs`. A channel that is disabled or misconfigured drops out
/// of delivery without touching the per-task switches.
final class PushDispatcher: @unchecked Sendable {

    static let shared = PushDispatcher()

    private init() {}

    // MARK: - Output change

    /// Stable fingerprint of the script's "output content".
    /// Prefers trimmed stdout; falls back to stderr when stdout is empty so
    /// failed runs still de-dupe on the error text.
    static func outputFingerprint(stdout: String, stderr: String) -> String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = out.isEmpty ? err : out
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// First run (`previous == nil`) always notifies. Later runs notify only
    /// when the fingerprint changed.
    static func shouldNotifyOnOutputChange(previousFingerprint: String?, currentFingerprint: String) -> Bool {
        previousFingerprint != currentFingerprint
    }

    // MARK: - Send

    /// Fire-and-forget push used after a task finishes. One request per
    /// channel, all in flight together — a slow endpoint must not delay the
    /// others, and none of them may delay the run that triggered them.
    func send(title: String, body: String, to channels: [PushChannel]) {
        guard !channels.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for channel in channels {
                    group.addTask {
                        let result = await Self.post(channel: channel, title: title, body: body)
                        if case .failure(let error) = result {
                            NSLog("⚠️ Push to \(channel.displayName) failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }

    /// Settings "Send Test" — waits for the HTTP response so the UI can report it.
    func sendTest(channel: PushChannel) async -> Result<Void, PushError> {
        await Self.post(
            channel: channel,
            title: L10n.tr("settings.push.test.title"),
            body: L10n.tr("settings.push.test.body")
        )
    }

    static func post(channel: PushChannel, title: String, body: String) async -> Result<Void, PushError> {
        // 企业微信自建应用 is two requests, not one — it has to fetch and cache
        // an access_token before it can send. Everything else is a single
        // request `PushRequestBuilder` can build up front.
        if channel.kind == .wecomApp {
            return await WeComSender.send(channel: channel, title: title, body: body)
        }

        let request: URLRequest
        switch PushRequestBuilder.makeRequest(for: channel, title: title, body: body) {
        case .success(let built): request = built
        case .failure(let error): return .failure(error)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error = PushRequestBuilder.interpret(kind: channel.kind, status: status, data: data) {
                return .failure(error)
            }
            return .success(())
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
