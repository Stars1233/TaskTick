import Foundation
import TaskTickCore

/// The push providers TaskTick knows how to talk to (issue #51).
///
/// TaskTick shipped with a single hard-coded Bark endpoint. Issue #51 asked for
/// Gotify "and some other notifications" — which is really a request for a
/// provider abstraction, not one more hard-coded channel: every extra provider
/// would otherwise bring its own model fields, Settings block and editor
/// toggles. So a channel is *data*; the only per-provider code is how that data
/// turns into an HTTP request (`PushRequestBuilder`).
///
/// `webhook` is deliberately generic — a free-form HTTP request covers ntfy,
/// Telegram, Slack, Discord, 企业微信群机器人, 钉钉 and friends without another
/// case here.
///
/// `wecomApp` is the exception that proves the rule (issue #54): a 企业微信
/// 自建应用 can't be reached by one HTTP request, because the send API needs an
/// `access_token` fetched from a *second* endpoint and cached for its 7200s
/// lifetime. That's state and a round trip the generic webhook has nowhere to
/// put — see `WeComPush.swift`.
enum PushProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bark
    case gotify
    case webhook
    case wecomApp = "wecom_app"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bark: return L10n.tr("push.kind.bark")
        case .gotify: return L10n.tr("push.kind.gotify")
        case .webhook: return L10n.tr("push.kind.webhook")
        case .wecomApp: return L10n.tr("push.kind.wecom_app")
        }
    }

    /// SF Symbol shown next to the channel in the settings list.
    var symbolName: String {
        switch self {
        case .bark: return "iphone.gen3"
        case .gotify: return "server.rack"
        case .webhook: return "link"
        case .wecomApp: return "building.2"
        }
    }
}

/// One user-configured remote endpoint. Persisted as JSON in UserDefaults by
/// `PushChannelStore`; referenced from a task by `id`.
struct PushChannel: Codable, Identifiable, Equatable, Hashable, Sendable {

    /// Starting point for a new webhook. JSON because that's what the vast
    /// majority of receivers want; the user is free to rewrite it.
    static let defaultWebhookBody = """
    {
      "title": "{{title}}",
      "body": "{{body}}"
    }
    """

    /// 企业微信 "everyone in the app's visible range". The sane default for the
    /// one-person virtual company most users will set this up with, and the
    /// value they'd otherwise have to look up. Clearing the field is an error
    /// rather than an implicit `@all` — nobody should widen their audience by
    /// emptying a text box.
    static let defaultWeComRecipient = "@all"

    var id: UUID
    var kind: PushProviderKind
    /// User-facing label. Empty falls back to `<kind> · <host>` so a row is
    /// never blank.
    var name: String
    /// Per-channel kill switch: silences one endpoint without deleting its
    /// config and without touching any task's own toggle.
    var isEnabled: Bool
    /// bark — device URL (`https://api.day.app/<key>`) or a bare device key.
    /// gotify — server base URL (`https://push.example.com`).
    /// webhook — the full request URL; supports `{{title}}` / `{{body}}`.
    var serverURL: String
    /// gotify application token / wecomApp 应用 Secret (`corpsecret`). Unused by
    /// the other kinds.
    var token: String
    /// gotify message priority (0…10). Unused by the other kinds.
    var priority: Int
    /// webhook HTTP method.
    var httpMethod: String
    /// webhook `Content-Type`. Also decides how `{{…}}` values get escaped —
    /// see `PushTemplate.Escaping`.
    var contentType: String
    /// webhook extra headers, as a JSON object string (`{"Authorization": "…"}`).
    var headersJSON: String
    /// webhook request body; supports `{{title}}` / `{{body}}`.
    var bodyTemplate: String
    /// wecomApp 企业 ID (`corpid`). Unused by the other kinds.
    var corpID: String
    /// wecomApp 应用 ID (`agentid`). Kept as a string because it's typed by
    /// hand — an `Int` field would turn a half-entered value into 0.
    var agentID: String
    /// wecomApp recipients (`touser`): member UserIDs joined by `|`, or `@all`.
    /// Unused by the other kinds.
    var toUser: String

    init(
        id: UUID = UUID(),
        kind: PushProviderKind = .bark,
        name: String = "",
        isEnabled: Bool = true,
        serverURL: String = "",
        token: String = "",
        priority: Int = 5,
        httpMethod: String = "POST",
        contentType: String = "application/json",
        headersJSON: String = "",
        bodyTemplate: String = PushChannel.defaultWebhookBody,
        corpID: String = "",
        agentID: String = "",
        toUser: String = PushChannel.defaultWeComRecipient
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isEnabled = isEnabled
        self.serverURL = serverURL
        self.token = token
        self.priority = priority
        self.httpMethod = httpMethod
        self.contentType = contentType
        self.headersJSON = headersJSON
        self.bodyTemplate = bodyTemplate
        self.corpID = corpID
        self.agentID = agentID
        self.toUser = toUser
    }

    /// Every field is decoded leniently. A config written by a different build
    /// (older, or a newer one that gained a field) must still load — throwing
    /// here would wipe every channel the user configured, and the settings list
    /// would come up empty with no explanation.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        self.kind = (try? c.decodeIfPresent(PushProviderKind.self, forKey: .kind)) ?? .bark
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.isEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        self.serverURL = (try? c.decodeIfPresent(String.self, forKey: .serverURL)) ?? ""
        self.token = (try? c.decodeIfPresent(String.self, forKey: .token)) ?? ""
        self.priority = (try? c.decodeIfPresent(Int.self, forKey: .priority)) ?? 5
        self.httpMethod = (try? c.decodeIfPresent(String.self, forKey: .httpMethod)) ?? "POST"
        self.contentType = (try? c.decodeIfPresent(String.self, forKey: .contentType)) ?? "application/json"
        self.headersJSON = (try? c.decodeIfPresent(String.self, forKey: .headersJSON)) ?? ""
        self.bodyTemplate = (try? c.decodeIfPresent(String.self, forKey: .bodyTemplate))
            ?? PushChannel.defaultWebhookBody
        self.corpID = (try? c.decodeIfPresent(String.self, forKey: .corpID)) ?? ""
        self.agentID = (try? c.decodeIfPresent(String.self, forKey: .agentID)) ?? ""
        self.toUser = (try? c.decodeIfPresent(String.self, forKey: .toUser))
            ?? PushChannel.defaultWeComRecipient
    }

    // MARK: - Display

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallbackName : trimmed
    }

    /// `Gotify · push.example.com`, or just the kind when the URL isn't
    /// parseable yet (a half-typed channel still needs a label).
    private var fallbackName: String {
        let raw = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let host = URLComponents(string: raw)?.host, !host.isEmpty else {
            return kind.displayName
        }
        return "\(kind.displayName) · \(host)"
    }

    // MARK: - Validation

    /// `nil` = this channel can send. Checked before every send *and* surfaced
    /// in the settings editor, so a misconfigured endpoint reports the same
    /// reason in both places instead of failing silently at run time.
    var validationError: PushError? {
        let url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case .bark:
            guard !url.isEmpty else { return .emptyURL }
            return BarkEndpoint.normalizedURL(from: url) == nil ? .invalidURL : nil
        case .gotify:
            guard !url.isEmpty else { return .emptyURL }
            guard GotifyEndpoint.messageURL(fromServer: url) != nil else { return .invalidURL }
            return token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .missingToken : nil
        case .webhook:
            guard !url.isEmpty else { return .emptyURL }
            // Probe with placeholder values: a URL template is only valid if it
            // still parses once `{{…}}` has been substituted.
            guard WebhookEndpoint.requestURL(from: url, title: "probe", body: "probe") != nil else {
                return .invalidURL
            }
            return WebhookEndpoint.parseHeaders(headersJSON) == nil ? .invalidHeaders : nil
        case .wecomApp:
            // No URL to check — the endpoint is fixed. What the user supplies
            // are the three credentials plus the recipient list.
            return wecomValidationError
        }
    }

    /// The four 企业微信 fields, checked in the order the editor lists them so
    /// the reported error points at the first box still needing attention.
    private var wecomValidationError: PushError? {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed(corpID).isEmpty else { return .missingCorpID }
        guard !trimmed(token).isEmpty else { return .missingSecret }
        // agentid goes into the JSON body as a number; a non-numeric value
        // would be rejected by 企业微信 with an errcode nobody can decode.
        guard Int(trimmed(agentID)) != nil else { return .invalidAgentID }
        guard !trimmed(toUser).isEmpty else { return .missingRecipient }
        return nil
    }

    var isValid: Bool { validationError == nil }

    /// Enabled *and* configured — the bar a channel has to clear to receive a
    /// task's completion push.
    var isReadyToSend: Bool { isEnabled && isValid }
}

/// Everything that can stop a push, from a half-filled form to a 500 from the
/// server. One type for both so the settings "Send Test" button and the
/// run-time log speak the same language.
enum PushError: LocalizedError, Equatable {
    case emptyURL
    case invalidURL
    case missingToken
    case missingCorpID
    case missingSecret
    case invalidAgentID
    case missingRecipient
    case invalidHeaders
    case invalidBody
    case httpStatus(Int)
    case serverMessage(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return L10n.tr("push.error.empty_url")
        case .invalidURL:
            return L10n.tr("push.error.invalid_url")
        case .missingToken:
            return L10n.tr("push.error.missing_token")
        case .missingCorpID:
            return L10n.tr("push.error.missing_corp_id")
        case .missingSecret:
            return L10n.tr("push.error.missing_secret")
        case .invalidAgentID:
            return L10n.tr("push.error.invalid_agent_id")
        case .missingRecipient:
            return L10n.tr("push.error.missing_recipient")
        case .invalidHeaders:
            return L10n.tr("push.error.invalid_headers")
        case .invalidBody:
            return L10n.tr("push.error.invalid_body")
        case .httpStatus(let code):
            return L10n.tr("push.error.http", code)
        case .serverMessage(let message):
            return message
        case .network(let message):
            return message
        }
    }
}
