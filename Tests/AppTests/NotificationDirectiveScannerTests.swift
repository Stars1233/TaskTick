import Testing
import Foundation
@testable import TaskTickApp

@Suite("NotificationDirectiveScanner Tests")
struct NotificationDirectiveScannerTests {

    private func str(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }

    @Test("Single complete directive (title + body) → 1 directive, line stripped")
    func singleDirective() {
        let s = NotificationDirectiveScanner()
        let (pass, dirs) = s.feed(Data(#"@tasktick:notify {"title":"Update","body":"v5.5.2"}"#.utf8) + Data("\n".utf8))
        #expect(dirs == [NotificationDirective(title: "Update", body: "v5.5.2")])
        #expect(pass.isEmpty)
    }

    @Test("Title-only directive → body == nil")
    func titleOnly() {
        let s = NotificationDirectiveScanner()
        let (pass, dirs) = s.feed(Data(#"@tasktick:notify {"title":"Done"}"#.utf8) + Data("\n".utf8))
        #expect(dirs == [NotificationDirective(title: "Done", body: nil)])
        #expect(pass.isEmpty)
    }

    @Test("Directive split across two feed() calls → 1 directive")
    func splitAcrossChunks() {
        let s = NotificationDirectiveScanner()
        let (p1, d1) = s.feed(Data(#"@tasktick:notify {"title":"Sp"#.utf8))
        #expect(d1.isEmpty)
        #expect(p1.isEmpty) // withheld: could still become a directive
        let (p2, d2) = s.feed(Data(#"lit"}"#.utf8) + Data("\n".utf8))
        #expect(d2 == [NotificationDirective(title: "Split", body: nil)])
        #expect(p2.isEmpty)
    }

    @Test("Directive without trailing newline recovered by flush()")
    func noTrailingNewline() {
        let s = NotificationDirectiveScanner()
        let (_, d1) = s.feed(Data(#"@tasktick:notify {"title":"Tail"}"#.utf8))
        #expect(d1.isEmpty) // no newline yet, withheld
        let (p2, d2) = s.flush()
        #expect(d2 == [NotificationDirective(title: "Tail", body: nil)])
        #expect(p2.isEmpty)
    }

    @Test("Invalid JSON after prefix → 0 directives, original line passed through")
    func invalidJSON() {
        let s = NotificationDirectiveScanner()
        let line = "@tasktick:notify {not valid json}\n"
        let (pass, dirs) = s.feed(Data(line.utf8))
        #expect(dirs.isEmpty)
        #expect(str(pass) == line)
    }

    @Test("Valid JSON but missing title → 0 directives, line passed through")
    func missingTitle() {
        let s = NotificationDirectiveScanner()
        let line = #"@tasktick:notify {"body":"no title"}"# + "\n"
        let (pass, dirs) = s.feed(Data(line.utf8))
        #expect(dirs.isEmpty)
        #expect(str(pass) == line)
    }

    @Test("Empty title → 0 directives, line passed through")
    func emptyTitle() {
        let s = NotificationDirectiveScanner()
        let line = #"@tasktick:notify {"title":""}"# + "\n"
        let (pass, dirs) = s.feed(Data(line.utf8))
        #expect(dirs.isEmpty)
        #expect(str(pass) == line)
    }

    @Test("Body wrong type (number) → fires with title, body ignored")
    func bodyWrongType() {
        let s = NotificationDirectiveScanner()
        let (_, dirs) = s.feed(Data(#"@tasktick:notify {"title":"T","body":42}"#.utf8) + Data("\n".utf8))
        #expect(dirs == [NotificationDirective(title: "T", body: nil)])
    }

    @Test("Unknown extra keys are ignored")
    func extraKeys() {
        let s = NotificationDirectiveScanner()
        let (_, dirs) = s.feed(Data(#"@tasktick:notify {"title":"T","sound":"x"}"#.utf8) + Data("\n".utf8))
        #expect(dirs == [NotificationDirective(title: "T", body: nil)])
    }

    @Test("Non-directive line beginning with @ but not the prefix → passthrough")
    func atButNotPrefix() {
        let s = NotificationDirectiveScanner()
        let line = "@echo something\n"
        let (pass, dirs) = s.feed(Data(line.utf8))
        #expect(dirs.isEmpty)
        #expect(str(pass) == line)
    }

    @Test("CR-heavy progress text with no newline → streamed immediately, not withheld")
    func progressBarStreamed() {
        let s = NotificationDirectiveScanner()
        let chunk = "Downloading: 50%\rDownloading: 80%"
        let (pass, dirs) = s.feed(Data(chunk.utf8))
        #expect(dirs.isEmpty)
        #expect(str(pass) == chunk) // not withheld despite missing newline
    }

    @Test("Interleaved normal lines and directives preserved in order")
    func interleaved() {
        let s = NotificationDirectiveScanner()
        let input = #"before"# + "\n" + #"@tasktick:notify {"title":"Mid"}"# + "\n" + "after\n"
        let (pass, dirs) = s.feed(Data(input.utf8))
        #expect(dirs == [NotificationDirective(title: "Mid", body: nil)])
        #expect(str(pass) == "before\nafter\n")
    }

    @Test("Leading-whitespace-indented directive is recognized")
    func leadingWhitespace() {
        let s = NotificationDirectiveScanner()
        let (pass, dirs) = s.feed(Data(#"    @tasktick:notify {"title":"Indented"}"#.utf8) + Data("\n".utf8))
        #expect(dirs == [NotificationDirective(title: "Indented", body: nil)])
        #expect(pass.isEmpty)
    }

    @Test("Directive carrying a leading ANSI color sequence is recognized")
    func leadingANSI() {
        let s = NotificationDirectiveScanner()
        let ansi = "\u{1B}[32m" + #"@tasktick:notify {"title":"Colored"}"# + "\u{1B}[0m\n"
        let (_, dirs) = s.feed(Data(ansi.utf8))
        #expect(dirs == [NotificationDirective(title: "Colored", body: nil)])
    }

    @Test("All directives returned in order (cap is applied downstream, not here)")
    func manyDirectives() {
        let s = NotificationDirectiveScanner()
        var input = ""
        for i in 0..<25 { input += #"@tasktick:notify {"title":"n\#(i)"}"# + "\n" }
        let (pass, dirs) = s.feed(Data(input.utf8))
        #expect(dirs.count == 25)
        #expect(dirs.first == NotificationDirective(title: "n0", body: nil))
        #expect(dirs.last == NotificationDirective(title: "n24", body: nil))
        #expect(pass.isEmpty)
    }

    @Test("Post-exit drain tail recognized via feed-then-flush")
    func drainTail() {
        let s = NotificationDirectiveScanner()
        let (p1, d1) = s.feed(Data("log line\n".utf8))
        #expect(str(p1) == "log line\n")
        #expect(d1.isEmpty)
        let (_, d2) = s.feed(Data(#"@tasktick:notify {"title":"Drain"}"#.utf8))
        #expect(d2.isEmpty) // no newline yet
        let (p3, d3) = s.flush()
        #expect(d3 == [NotificationDirective(title: "Drain", body: nil)])
        #expect(p3.isEmpty)
    }
}
