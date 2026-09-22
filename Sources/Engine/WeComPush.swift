import Foundation
import TaskTickCore

/// 企业微信自建应用 push (issue #54).
///
/// Every other provider in `PushRequestBuilder` is one request built from the
/// channel's own fields. 自建应用 isn't: sending needs an `access_token` that
/// only a second endpoint can mint, that lasts 7200s, and that 企业微信's docs
/// explicitly require callers to cache — fetching one per push earns a
/// frequency block. So this kind gets its own async path, routed here from
/// `PushDispatcher.post`, and `PushRequestBuilder.makeRequest` never sees it.
enum WeComEndpoint {

    /// Fixed host — 企业微信 has no self-hosted deployment, so unlike Gotify
    /// there is no server URL for the user to get wrong.
    static let apiBase = "https://qyapi.weixin.qq.com"

    /// `GET /cgi-bin/gettoken?corpid=&corpsecret=`
    static func tokenURL(corpID: String, secret: String) -> URL? {
        guard var components = URLComponents(string: "\(apiBase)/cgi-bin/gettoken") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "corpid", value: corpID),
            URLQueryItem(name: "corpsecret", value: secret)
        ]
        return components.url
    }

    /// `POST /cgi-bin/message/send?access_token=`
    static func sendURL(accessToken: String) -> URL? {
        guard var components = URLComponents(string: "\(apiBase)/cgi-bin/message/send") else { return nil }
        components.queryItems = [URLQueryItem(name: "access_token", value: accessToken)]
        return components.url
    }

    /// A `text` message carries at most 2048 bytes of content. A task that
    /// prints a stack trace would otherwise get the whole push rejected, so the
    /// body is cut to fit and marked with an ellipsis.
    static let maxContentBytes = 2000

    static func clampedContent(_ text: String, maxBytes: Int = maxContentBytes) -> String {
        var bytes = Data(text.utf8)
        guard bytes.count > maxBytes else { return text }
        bytes = bytes.prefix(maxBytes)
        // Back off until the cut lands on a UTF-8 boundary — slicing mid-
        // character yields nil, not a replacement character.
        while !bytes.isEmpty, String(data: bytes, encoding: .utf8) == nil {
            bytes = bytes.dropLast()
        }
        return (String(data: bytes, encoding: .utf8) ?? "") + "…"
    }

    /// Masks credentials in text that's headed for `NSLog` or an alert.
    ///
    /// Both endpoints carry their credential in the query string, and URLSession
    /// errors sometimes quote the failing request — which would drop a live
    /// secret into the system log, where any app can read it.
    static func redacted(_ message: String, hiding secrets: [String]) -> String {
        var result = message
        // Short values would match half the sentence; a real corpsecret and
        // access_token are far longer than this.
        for secret in secrets where secret.count >= 8 {
            result = result.replacingOccurrences(of: secret, with: "***")
        }
        return result
    }

    /// The request body 企业微信 expects for a plain text message.
    ///
    /// `title` and `body` are joined rather than mapped to separate fields:
    /// `msgtype: text` has no title of its own, and `textcard` — which does —
    /// requires a click-through URL TaskTick has nothing to put in.
    static func messagePayload(channel: PushChannel, title: String, body: String) -> [String: Any]? {
        guard let agentID = Int(channel.agentID.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = [trimmedTitle, trimmedBody]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return [
            "touser": channel.toUser.trimmingCharacters(in: .whitespacesAndNewlines),
            "msgtype": "text",
            "agentid": agentID,
            "text": ["content": clampedContent(content)]
        ]
    }
}

// MARK: - Token cache

/// Caches one `access_token` per (corpid, secret) pair for the lifetime of the
/// app process.
///
/// Deliberately in memory only: the token is a 2-hour credential, and writing
/// it to disk would put a live key next to the config for no gain — a relaunch
/// just fetches a fresh one.
actor WeComTokenStore {

    static let shared = WeComTokenStore()

    private struct CachedToken: Sendable {
        let value: String
        let expiresAt: Date
    }

    private var cache: [String: CachedToken] = [:]
    /// In-flight fetches, so N tasks finishing at once make one `gettoken` call
    /// rather than N — which is exactly the pattern 企业微信 rate-limits.
    private var inFlight: [String: Task<CachedToken, any Error>] = [:]

    /// 企业微信 may expire a token early, so the cached copy is retired well
    /// before its nominal deadline; a stale one still costs only a retry.
    private static let expirySafetyMargin: TimeInterval = 300
    private static let minimumLifetime: TimeInterval = 60

    func accessToken(corpID: String, secret: String) async -> Result<String, PushError> {
        let key = Self.cacheKey(corpID: corpID, secret: secret)

        if let cached = cache[key], cached.expiresAt > Date() {
            return .success(cached.value)
        }

        let task: Task<CachedToken, any Error>
        if let existing = inFlight[key] {
            task = existing
        } else {
            task = Task { try await Self.fetchToken(corpID: corpID, secret: secret) }
            inFlight[key] = task
        }

        do {
            let fetched = try await task.value
            cache[key] = fetched
            inFlight[key] = nil
            return .success(fetched.value)
        } catch {
            inFlight[key] = nil
            if let pushError = error as? PushError { return .failure(pushError) }
            return .failure(.network(
                WeComEndpoint.redacted(error.localizedDescription, hiding: [secret])
            ))
        }
    }

    /// Drops a token 企业微信 rejected, so the retry mints a new one.
    func invalidate(corpID: String, secret: String) {
        cache[Self.cacheKey(corpID: corpID, secret: secret)] = nil
    }

    /// Both halves are part of the identity: one 企业 has a different token per
    /// app, and the same app re-keyed gets a different token too.
    private static func cacheKey(corpID: String, secret: String) -> String {
        "\(corpID)\u{1}\(secret)"
    }

    private static func fetchToken(corpID: String, secret: String) async throws -> CachedToken {
        guard let url = WeComEndpoint.tokenURL(corpID: corpID, secret: secret) else {
            throw PushError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1

        guard let payload = try? JSONDecoder().decode(WeComAPIResponse.self, from: data) else {
            throw status >= 400 ? PushError.httpStatus(status) : PushError.invalidBody
        }
        if let error = payload.pushError { throw error }
        guard let token = payload.access_token, !token.isEmpty else {
            throw PushError.missingToken
        }

        let lifetime = TimeInterval(payload.expires_in ?? 7200) - expirySafetyMargin
        return CachedToken(
            value: token,
            expiresAt: Date().addingTimeInterval(max(lifetime, minimumLifetime))
        )
    }
}

// MARK: - Send

enum WeComSender {

    static func send(channel: PushChannel, title: String, body: String) async -> Result<Void, PushError> {
        if let error = channel.validationError { return .failure(error) }
        return await attempt(channel: channel, title: title, body: body, allowingRetry: true)
    }

    /// One send. On an expired/revoked token the cached copy is dropped and the
    /// whole thing runs once more — `allowingRetry` is what keeps that from
    /// looping when 企业微信 keeps saying the token is bad.
    private static func attempt(
        channel: PushChannel,
        title: String,
        body: String,
        allowingRetry: Bool
    ) async -> Result<Void, PushError> {
        let corpID = channel.corpID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = channel.token.trimmingCharacters(in: .whitespacesAndNewlines)

        let accessToken: String
        switch await WeComTokenStore.shared.accessToken(corpID: corpID, secret: secret) {
        case .success(let token): accessToken = token
        case .failure(let error): return .failure(error)
        }

        guard let url = WeComEndpoint.sendURL(accessToken: accessToken) else {
            return .failure(.invalidURL)
        }
        guard let payload = WeComEndpoint.messagePayload(channel: channel, title: title, body: body),
              let httpBody = try? JSONSerialization.data(withJSONObject: payload)
        else {
            return .failure(.invalidBody)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1

            if allowingRetry,
               let payload = try? JSONDecoder().decode(WeComAPIResponse.self, from: data),
               payload.isExpiredToken {
                await WeComTokenStore.shared.invalidate(corpID: corpID, secret: secret)
                return await attempt(channel: channel, title: title, body: body, allowingRetry: false)
            }

            if let error = PushRequestBuilder.interpret(kind: .wecomApp, status: status, data: data) {
                return .failure(error)
            }
            return .success(())
        } catch {
            return .failure(.network(
                WeComEndpoint.redacted(error.localizedDescription, hiding: [secret, accessToken])
            ))
        }
    }
}

// MARK: - API response

/// Both 企业微信 endpoints answer in this one shape, always with HTTP 200 —
/// the status code tells you nothing, `errcode` tells you everything.
struct WeComAPIResponse: Decodable {
    let errcode: Int?
    let errmsg: String?
    let access_token: String?
    let expires_in: Int?
    /// Recipients that don't exist or can't receive. Comes back *alongside*
    /// `errcode: 0` — a push that silently reached nobody.
    let invaliduser: String?

    /// 40014 invalid access_token · 42001 access_token expired ·
    /// 41001 access_token missing. All three mean "mint a new one and retry".
    var isExpiredToken: Bool {
        guard let errcode else { return false }
        return [40014, 42001, 41001].contains(errcode)
    }

    /// `nil` when 企业微信 accepted the call outright.
    var pushError: PushError? {
        if let errcode, errcode != 0 {
            let message = errmsg?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .serverMessage(
                message.map { "\($0) (\(errcode))" } ?? L10n.tr("push.error.http", errcode)
            )
        }
        // errcode 0 with every recipient invalid is the classic 自建应用
        // mistake: a UserID that's actually a name or a phone number. Reporting
        // it as an error is what makes "Send Test" worth pressing.
        if let invalid = invaliduser?.trimmingCharacters(in: .whitespacesAndNewlines), !invalid.isEmpty {
            return .serverMessage(L10n.tr("push.error.wecom_invalid_user", invalid))
        }
        return nil
    }
}
