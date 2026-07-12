import Testing
@testable import TaskTickApp

@Suite("SudoTTYFailure Tests")
struct SudoTTYFailureTests {

    @Test("macOS sudo 标准报错（a terminal is required）→ 命中")
    func terminalRequiredMessage() {
        let stderr = "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper"
        #expect(SudoTTYFailure.matches(stderr: stderr))
    }

    @Test("sudo 旧版/askpass 变体（no tty present）→ 命中")
    func noTTYPresentMessage() {
        let stderr = "sudo: no tty present and no askpass program specified"
        #expect(SudoTTYFailure.matches(stderr: stderr))
    }

    @Test("报错混在多行脚本输出中 → 命中")
    func messageEmbeddedInOtherOutput() {
        let stderr = """
        Fetching updates...
        sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper
        exit status 1
        """
        #expect(SudoTTYFailure.matches(stderr: stderr))
    }

    @Test("普通失败输出 → 不命中")
    func unrelatedStderr() {
        #expect(!SudoTTYFailure.matches(stderr: "curl: (6) Could not resolve host: example.com"))
    }

    @Test("nil stderr → 不命中")
    func nilStderr() {
        #expect(!SudoTTYFailure.matches(stderr: nil))
    }

    @Test("空字符串 → 不命中")
    func emptyStderr() {
        #expect(!SudoTTYFailure.matches(stderr: ""))
    }

    @Test("含相似措辞但与 sudo 无关 → 不命中")
    func similarPhraseWithoutSudo() {
        let stderr = "myapp: a terminal is required to read the password"
        #expect(!SudoTTYFailure.matches(stderr: stderr))
    }
}
