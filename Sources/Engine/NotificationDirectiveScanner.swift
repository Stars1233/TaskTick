import Foundation

/// A notification requested by a running script via a stdout sentinel line.
struct NotificationDirective: Equatable, Sendable {
    let title: String
    let body: String?
}

/// Scans a live stdout byte stream for `@tasktick:notify {json}` sentinel lines,
/// strips them from the passthrough bytes, and surfaces them as directives.
///
/// Stateful (it buffers the trailing partial line across chunks) and fed from
/// two queues — the readabilityHandler thread and the post-exit drain queue —
/// so every access is guarded by an `NSLock`, mirroring `PipeOutputBuffer` and
/// `IOBatcher`. Hence `@unchecked Sendable`.
///
/// Stream-safety: a trailing partial line (no newline yet) is released to
/// passthrough immediately *unless* it could still become a directive (its
/// bytes form a prefix of the sentinel). This keeps `\r`-driven progress bars
/// and other newline-less output flowing instead of stalling.
///
/// Fault tolerance: any decode/parse failure degrades to "treat as ordinary
/// output" — the original line passes through verbatim, never a crash.
final class NotificationDirectiveScanner: @unchecked Sendable {

    private static let sentinel = "@tasktick:notify"
    private static let sentinelBytes = Array("@tasktick:notify".utf8)
    /// Safety cap: stop withholding a "could-be-directive" partial line once it
    /// grows past this, so a runaway script that prints the prefix then gigabytes
    /// without a newline can't pin output in the buffer forever.
    private static let maxWithholdBytes = 1 << 20 // 1 MB

    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> (passthrough: Data, directives: [NotificationDirective]) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)

        var out = Data()
        var directives: [NotificationDirective] = []

        // Drain every complete line (terminated by \n).
        while let nl = buffer.firstIndex(of: 0x0A) {
            let afterNL = buffer.index(after: nl)
            let lineBytes = Data(buffer[buffer.startIndex..<nl]) // without the \n
            if let directive = Self.parseDirective(lineBytes) {
                directives.append(directive) // strip the directive line and its \n
            } else {
                out.append(buffer[buffer.startIndex..<afterNL]) // line + \n, verbatim
            }
            buffer.removeSubrange(buffer.startIndex..<afterNL)
        }

        // Trailing partial line (no \n): release unless it might still be a directive.
        if !buffer.isEmpty,
           !Self.couldBeDirectivePrefix(buffer) || buffer.count > Self.maxWithholdBytes {
            out.append(buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        return (out, directives)
    }

    /// Call after the process exits AND after the final drained chunk has been
    /// `feed()`-ed: treat any buffered partial line as a final line (handles a
    /// last directive printed without a trailing newline).
    func flush() -> (passthrough: Data, directives: [NotificationDirective]) {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return (Data(), []) }

        var out = Data()
        var directives: [NotificationDirective] = []
        if let directive = Self.parseDirective(buffer) {
            directives.append(directive)
        } else {
            out.append(buffer)
        }
        buffer.removeAll(keepingCapacity: false)
        return (out, directives)
    }

    // MARK: - Parsing

    /// Parse one line's raw bytes into a directive, or nil if it isn't one.
    /// Decodes with the same `decodeProcessOutput` helper the sinks use, so a
    /// directive carrying leading ANSI (colored logs, `set -x`) is recognized.
    private static func parseDirective(_ lineBytes: Data) -> NotificationDirective? {
        let text = decodeProcessOutput(lineBytes)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(sentinel) else { return nil }

        let jsonPart = String(trimmed.dropFirst(sentinel.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let jsonData = jsonPart.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData),
              let dict = object as? [String: Any],
              let title = dict["title"] as? String,
              !title.isEmpty else {
            return nil // malformed → caller passes the original line through
        }
        let body = dict["body"] as? String // wrong type / absent → nil (be liberal)
        return NotificationDirective(title: title, body: body)
    }

    /// Whether a trailing partial line (no newline) could still become a
    /// directive — i.e. its bytes, after leading ASCII whitespace, are a prefix
    /// of (or start with) the sentinel. Cheap ASCII check; no decode.
    private static func couldBeDirectivePrefix(_ bytes: Data) -> Bool {
        var i = bytes.startIndex
        while i < bytes.endIndex, bytes[i] == 0x20 || bytes[i] == 0x09 {
            i = bytes.index(after: i)
        }
        let rest = bytes[i...]
        if rest.isEmpty { return true } // leading whitespace may precede a directive
        for (k, byte) in rest.enumerated() {
            if k >= sentinelBytes.count { return true } // already starts with full sentinel
            if byte != sentinelBytes[k] { return false } // diverges → cannot be a directive
        }
        return true // a proper prefix of the sentinel
    }
}
