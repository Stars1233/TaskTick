import Testing
@testable import TaskTickApp

@Suite("LineBuffer Tests")
struct LineBufferTests {

    @Test("Empty buffer materializes to empty string")
    func emptyBuffer() {
        let buf = LineBuffer()
        #expect(buf.materialize() == "")
        #expect(buf.isEmpty == true)
    }

    @Test("Append complete lines")
    func appendCompleteLines() {
        var buf = LineBuffer()
        buf.append("hello\n")
        buf.append("world\n")
        #expect(buf.materialize() == "hello\nworld")
    }

    @Test("Append incomplete trailing line lives in pending")
    func incompleteTrailing() {
        var buf = LineBuffer()
        buf.append("partial")
        #expect(buf.materialize() == "partial")
        // Now complete it
        buf.append(" more\n")
        #expect(buf.materialize() == "partial more")
    }

    @Test("Multiple newlines in single chunk")
    func multipleNewlinesInChunk() {
        var buf = LineBuffer()
        buf.append("line1\nline2\nline3\n")
        #expect(buf.materialize() == "line1\nline2\nline3")
    }

    @Test("CR overwrites within a line (terminal semantics)")
    func crOverwrite() {
        var buf = LineBuffer()
        // Progress-bar-style update: \r resets the line
        buf.append("Downloading: 50%\rDownloading: 80%\n")
        #expect(buf.materialize() == "Downloading: 80%")
    }

    @Test("CRLF (\\r\\n) is treated as a single line ending, not CR-reset")
    func crlfLineEnding() {
        var buf = LineBuffer()
        // Windows-style line endings should produce normal lines, not empty
        // ones. Earlier draft of the buffer incorrectly applied CR-overwrite
        // to "Line\r" which produced "" as the line.
        buf.append("Line1\r\nLine2\r\n")
        #expect(buf.materialize() == "Line1\nLine2")
    }

    @Test("CR-only in pending (progress bar, no newline yet)")
    func crProgressBarNoNewline() {
        var buf = LineBuffer()
        buf.append("Progress: 10%\rProgress: 50%\rProgress: 90%")
        // No newline — everything's pending. The last CR resets pending.
        #expect(buf.materialize() == "Progress: 90%")
    }

    @Test("CR followed by content across two chunks")
    func crAcrossChunks() {
        var buf = LineBuffer()
        buf.append("first\r")
        buf.append("second\n")
        // The pending "first\r" then receives "second\n" — together the line
        // is "first\rsecond" which CR-resolves to "second".
        #expect(buf.materialize() == "second")
    }

    @Test("Empty chunk is a no-op")
    func emptyChunk() {
        var buf = LineBuffer()
        buf.append("hello\n")
        buf.append("")
        #expect(buf.materialize() == "hello")
    }

    @Test("Many lines amortized-trim to maxLines")
    func amortizedTrim() {
        var buf = LineBuffer(maxLines: 100, trimChunk: 50)
        for i in 0..<200 {
            buf.append("line \(i)\n")
        }
        // After 200 inserts and trim threshold 100+50=150, we should have
        // trimmed at least once. The exact count depends on when the trim
        // fired, but it must not exceed maxLines + trimChunk and must
        // contain the most recent lines.
        let materialized = buf.materialize()
        let lineCount = materialized.split(separator: "\n").count
        #expect(lineCount <= 150)
        #expect(materialized.hasSuffix("line 199"))
    }

    @Test("Pending overflow promotes to a line (no unbounded growth)")
    func pendingOverflow() {
        var buf = LineBuffer(maxLines: 1000, trimChunk: 100, maxPendingBytes: 100)
        // Append a chunk much larger than maxPendingBytes with no newline.
        let big = String(repeating: "x", count: 500)
        buf.append(big)
        // Pending must not exceed maxPendingBytes; overflow promoted to lines.
        #expect(buf.pending.utf8.count <= 100)
        #expect(buf.lines.count >= 1)
    }

    @Test("Mixed stdout-style traffic — many small chunks")
    func realisticTraffic() {
        var buf = LineBuffer()
        for i in 0..<1000 {
            buf.append("[INFO] iteration \(i) completed\n")
        }
        let materialized = buf.materialize()
        // Should contain the last line at the bottom
        #expect(materialized.hasSuffix("[INFO] iteration 999 completed"))
        // And the first line at the top (well within default cap of 5000)
        #expect(materialized.hasPrefix("[INFO] iteration 0 completed"))
    }
}
