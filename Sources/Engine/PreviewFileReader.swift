import Foundation

/// Reads a script file for preview display with a hard size cap, so a huge
/// (or hot, frequently-rewritten) file can never stall the main thread or
/// balloon memory — the preview only ever needs the head of the file.
enum PreviewFileReader {
    static func read(path: String, maxBytes: Int = 64 * 1024) -> (content: String, truncated: Bool)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // Read one extra byte purely to distinguish "exactly at cap" from
        // "there is more".
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { return nil }

        let truncated = data.count > maxBytes
        var slice = truncated ? data.prefix(maxBytes) : data[...]

        // A UTF-8 code point is at most 4 bytes; if the cap split one in half,
        // dropping up to 3 trailing bytes lands us on a clean boundary. A file
        // that still fails to decode is genuinely not UTF-8 → nil, matching
        // the previous String(contentsOfFile:encoding:) behavior.
        for _ in 0..<4 {
            if let content = String(data: slice, encoding: .utf8) {
                return (content, truncated)
            }
            guard truncated, !slice.isEmpty else { break }
            slice = slice.dropLast()
        }
        return nil
    }
}
