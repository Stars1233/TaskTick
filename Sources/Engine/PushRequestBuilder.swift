import Foundation
import TaskTickCore

/// Turns a `PushChannel` + a rendered title/body into an HTTP request, and
/// reads the provider's answer back into a `PushError`.
///
/// This is the *only* place that knows a provider's wire format. Adding a
/// fourth provider means one case in each of the two switches below plus an
/// endpoint helper — nothing in the model, the executor or the UI.
enum PushRequestBuilder {

    static func makeRequest(for channel: PushChannel, title: String, body: String) -> Result<URLRequest, PushError> {
        if let error = channel.validationError { return .failure(error) }

        switch channel.kind {
        case .bark:
            return barkRequest(channel: channel, title: title, body: body)
        case .gotify:
            return gotifyRequest(channel: channel, title: title, body: body)
        case .webhook:
            return webhookRequest(channel: channel, title: title, body: body)
        case .wecomApp:
            // Unreachable: 企业微信 needs an access_token fetched first, so
            // `PushDispatcher.post` routes this kind to `WeComSender` before it
            // gets here. Kept as a real error rather than a trap — a future
            // call site that forgets the routing should fail visibly, not crash.
            return .failure(.network(L10n.tr("push.error.internal")))
        }
    }

    /// Providers answer failures in their own JSON shape *and* sometimes with a
    /// 200. Read the body first, fall back to the status code.
    static func interpret(kind: PushProviderKind, status: Int, data: Data) -> PushError? {
        switch kind {
        case .bark:
            // Bark reports application errors in the body: {"code":400,"message":"…"}
            if let server = try? JSONDecoder().decode(BarkAPIResponse.self, from: data),
               let code = server.code, code != 200 {
                return .serverMessage(server.message ?? "code \(code)")
            }
        case .gotify:
            // {"error":"Unauthorized","errorCode":401,"errorDescription":"…"}
            if let server = try? JSONDecoder().decode(GotifyAPIError.self, from: data),
               let description = server.errorDescription ?? server.error {
                return .serverMessage(description)
            }
        case .webhook:
            // Arbitrary receiver — the status code is all we can trust.
            break
        case .wecomApp:
            // Always HTTP 200; the verdict is in {"errcode":…,"errmsg":…}, and
            // errcode 0 can still mean "delivered to nobody".
            if let server = try? JSONDecoder().decode(WeComAPIResponse.self, from: data) {
                return server.pushError
            }
        }
        return status >= 400 ? .httpStatus(status) : nil
    }

    // MARK: - Bark

    private static func barkRequest(channel: PushChannel, title: String, body: String) -> Result<URLRequest, PushError> {
        guard let url = BarkEndpoint.normalizedURL(from: channel.serverURL) else {
            return .failure(.invalidURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = ["title": title, "body": body, "group": "TaskTick"]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.invalidBody)
        }
        request.httpBody = data
        return .success(request)
    }

    // MARK: - Gotify

    private static func gotifyRequest(channel: PushChannel, title: String, body: String) -> Result<URLRequest, PushError> {
        guard let url = GotifyEndpoint.messageURL(fromServer: channel.serverURL) else {
            return .failure(.invalidURL)
        }
        let token = channel.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failure(.missingToken) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        // Header rather than `?token=`: keeps the app token out of the server's
        // access log, which query strings routinely land in.
        request.setValue(token, forHTTPHeaderField: "X-Gotify-Key")

        // `message` is the only required field; `priority` is clamped to the
        // range Gotify's clients actually interpret.
        let payload: [String: Any] = [
            "title": title,
            "message": body,
            "priority": min(max(channel.priority, 0), 10)
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return .failure(.invalidBody)
        }
        request.httpBody = data
        return .success(request)
    }

    // MARK: - Webhook

    private static func webhookRequest(channel: PushChannel, title: String, body: String) -> Result<URLRequest, PushError> {
        guard let url = WebhookEndpoint.requestURL(from: channel.serverURL, title: title, body: body) else {
            return .failure(.invalidURL)
        }
        guard let headers = WebhookEndpoint.parseHeaders(channel.headersJSON) else {
            return .failure(.invalidHeaders)
        }

        let method = channel.httpMethod.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        var request = URLRequest(url: url)
        request.httpMethod = method.isEmpty ? "POST" : method
        request.timeoutInterval = timeout

        let contentType = channel.contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        if !contentType.isEmpty {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        // User headers last so they can override the Content-Type above.
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        // GET/HEAD carry their payload in the URL (that's what the `{{…}}`
        // support in `serverURL` is for) — attaching a body would be ignored
        // at best and rejected at worst.
        if !["GET", "HEAD"].contains(request.httpMethod ?? "POST") {
            let rendered = PushTemplate.render(
                channel.bodyTemplate,
                title: title,
                body: body,
                escaping: PushTemplate.Escaping(forContentType: contentType)
            )
            request.httpBody = Data(rendered.utf8)
        }
        return .success(request)
    }

    private static let timeout: TimeInterval = 12
}

// MARK: - Endpoints

/// Bark URL handling. Unchanged from the single-provider era — the shapes
/// users paste (full device URL, self-hosted URL, bare device key) haven't.
enum BarkEndpoint {

    /// Accepts the URL copied from the Bark app (`https://api.day.app/<key>/`)
    /// or a bare device key. Trailing slashes are stripped; query items kept.
    static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            candidate = trimmed
        } else if trimmed.contains("://") {
            return nil
        } else {
            let key = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                return nil
            }
            candidate = "https://api.day.app/\(key)"
        }

        guard var components = URLComponents(string: candidate) else { return nil }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        while components.path.hasSuffix("/") && components.path.count > 1 {
            components.path.removeLast()
        }
        // Official Bark URLs always carry the device key as the first path
        // component. A host-only URL (https://api.day.app) cannot push.
        if components.path.isEmpty || components.path == "/" {
            return nil
        }
        return components.url
    }
}

/// Gotify's push API: `POST <server>/message`, app token in `X-Gotify-Key`.
enum GotifyEndpoint {

    /// Builds the message URL from whatever the user pasted. Bare hosts get
    /// `https://`, a trailing `/message` (copied from the docs) isn't doubled,
    /// and a sub-path deployment (`https://example.com/gotify`) is preserved.
    static func messageURL(fromServer raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            guard scheme == "http" || scheme == "https" else { return nil }
            candidate = trimmed
        } else if trimmed.contains("://") {
            return nil
        } else {
            candidate = "https://\(trimmed)"
        }

        guard var components = URLComponents(string: candidate),
              let host = components.host, !host.isEmpty
        else { return nil }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/message") {
            path += "/message"
        }
        components.path = path
        // The token travels in a header; a `?token=` the user pasted along with
        // the URL still works, so query items are left alone.
        return components.url
    }
}

/// Free-form HTTP webhook. Deliberately dumb: we substitute, we send, the user
/// owns the shape.
enum WebhookEndpoint {

    /// URL-level templating is what makes ntfy / Telegram-style receivers work
    /// (`…/sendMessage?chat_id=1&text={{body}}`), so values are percent-encoded
    /// for a query component here rather than JSON-escaped.
    static func requestURL(from template: String, title: String, body: String) -> URL? {
        let rendered = PushTemplate.render(template, title: title, body: body, escaping: .urlQuery)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rendered.isEmpty,
              let components = URLComponents(string: rendered),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// `nil` = the text isn't a JSON object of strings. Empty/whitespace is
    /// valid and means "no extra headers".
    static func parseHeaders(_ json: String) -> [String: String]? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        var headers: [String: String] = [:]
        for (key, value) in object {
            // Numbers and booleans are common in hand-written JSON; render them
            // rather than rejecting the whole header set over one `"retry": 3`.
            switch value {
            case let string as String: headers[key] = string
            case let number as NSNumber: headers[key] = number.stringValue
            default: return nil
            }
        }
        return headers
    }
}

// MARK: - Templating

/// `{{title}}` / `{{body}}` substitution for webhook URLs and bodies.
///
/// Escaping is not optional: dropping raw script output into
/// `{"text": "{{body}}"}` produces invalid JSON the moment the script prints a
/// quote or a newline — and the receiver rejects it with a 400 the user has no
/// way to explain.
enum PushTemplate {

    enum Escaping {
        case json
        case formURLEncoded
        case urlQuery
        case none

        /// Picked from the channel's declared Content-Type, so the escaping
        /// always matches the payload the user says they're sending.
        init(forContentType contentType: String) {
            let lowered = contentType.lowercased()
            if lowered.contains("json") {
                self = .json
            } else if lowered.contains("x-www-form-urlencoded") {
                self = .formURLEncoded
            } else {
                self = .none
            }
        }
    }

    /// Replaces back-to-front so a substituted value that itself contains
    /// `{{…}}` (a script echoing a template) isn't expanded a second time —
    /// same rule as `NotificationTemplate`.
    static func render(_ template: String, title: String, body: String, escaping: Escaping) -> String {
        let values = [
            "title": escape(title, using: escaping),
            "body": escape(body, using: escaping)
        ]
        guard let regex = placeholderRegex else { return template }
        let ns = template as NSString
        let matches = regex.matches(in: template, range: NSRange(location: 0, length: ns.length))

        var result = template
        for match in matches.reversed() {
            guard match.numberOfRanges == 2,
                  let range = Range(match.range, in: template),
                  let keyRange = Range(match.range(at: 1), in: template)
            else { continue }
            let key = String(template[keyRange]).lowercased()
            guard let value = values[key] else { continue } // unknown → leave as typed
            result.replaceSubrange(range, with: value)
        }
        return result
    }

    /// Compiled once: `PushChannel.validationError` renders a probe URL, and
    /// that runs on every settings row redraw and every channel resolution.
    private static let placeholderRegex = try? NSRegularExpression(
        pattern: #"\{\{\s*([A-Za-z]+)\s*\}\}"#
    )

    private static func escape(_ value: String, using escaping: Escaping) -> String {
        switch escaping {
        case .none:
            return value
        case .json:
            // Encode as a JSON string, then drop the surrounding quotes — the
            // template supplies those. Foundation handles the control
            // characters a shell script actually emits (\n, \t, \", \\).
            guard let data = try? JSONEncoder().encode(value),
                  let quoted = String(data: data, encoding: .utf8),
                  quoted.count >= 2
            else { return value }
            return String(quoted.dropFirst().dropLast())
        case .formURLEncoded, .urlQuery:
            // `&`, `=`, `+` and `#` are structural in both contexts and are NOT
            // in urlQueryAllowed — subtract them explicitly.
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#?/")
            return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
    }
}

// MARK: - Provider response shapes

private struct BarkAPIResponse: Decodable {
    let code: Int?
    let message: String?
}

private struct GotifyAPIError: Decodable {
    let error: String?
    let errorDescription: String?
}
