import Testing
import Foundation
@testable import TaskTickApp

@Suite("PreviewFileReader Tests")
struct PreviewFileReaderTests {

    private func makeTempFile(_ data: Data) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("preview-reader-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("script.sh")
        try data.write(to: url)
        return url.path
    }

    @Test("小文件 → 完整内容，未截断")
    func smallFileFullContent() throws {
        let path = try makeTempFile(Data("echo hello\n".utf8))
        let result = try #require(PreviewFileReader.read(path: path))
        #expect(result.content == "echo hello\n")
        #expect(!result.truncated)
    }

    @Test("超过上限 → 截断到上限，truncated 标记为 true")
    func largeFileTruncated() throws {
        let path = try makeTempFile(Data(String(repeating: "a", count: 100).utf8))
        let result = try #require(PreviewFileReader.read(path: path, maxBytes: 16))
        #expect(result.content == String(repeating: "a", count: 16))
        #expect(result.truncated)
    }

    @Test("恰好等于上限 → 不算截断")
    func exactlyAtCapNotTruncated() throws {
        let path = try makeTempFile(Data(String(repeating: "a", count: 16).utf8))
        let result = try #require(PreviewFileReader.read(path: path, maxBytes: 16))
        #expect(result.content.count == 16)
        #expect(!result.truncated)
    }

    @Test("多字节字符正好跨在截断边界上 → 回退到合法 UTF-8 边界，不产生乱码")
    func multibyteBoundaryTrimmed() throws {
        // "aaaa" + "中"(3 bytes) → cap at 5 splits 中 in half
        let path = try makeTempFile(Data("aaaa中中中".utf8))
        let result = try #require(PreviewFileReader.read(path: path, maxBytes: 5))
        #expect(result.content == "aaaa")
        #expect(result.truncated)
    }

    @Test("文件不存在 → nil")
    func missingFileReturnsNil() {
        #expect(PreviewFileReader.read(path: "/nonexistent/nope.sh") == nil)
    }

    @Test("整个文件不是合法 UTF-8 → nil（与旧行为一致）")
    func invalidUTF8ReturnsNil() throws {
        let path = try makeTempFile(Data([0xFF, 0xFE, 0xFA, 0x01]))
        #expect(PreviewFileReader.read(path: path) == nil)
    }
}
