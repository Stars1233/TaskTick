import Testing
import Foundation

/// Guards against malformed .strings files (e.g. an unescaped quote inside a
/// value). A single bad entry makes Foundation reject the WHOLE file at
/// runtime, silently disabling that language — the build still succeeds, so
/// only a parse check catches it.
@Suite("Localization Files Tests")
struct LocalizationFilesTests {

    private var localizationDir: URL {
        // Tests/AppTests/LocalizationFilesTests.swift → repo root → Sources/...
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TaskTickCore/Localization")
    }

    @Test("每个 .lproj 的 Localizable.strings 都能被 Foundation 解析")
    func allStringsFilesParse() throws {
        let lprojs = try FileManager.default
            .contentsOfDirectory(at: localizationDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
        #expect(!lprojs.isEmpty, "未找到任何 .lproj 目录，路径推导可能失效")

        for lproj in lprojs {
            let file = lproj.appendingPathComponent("Localizable.strings")
            let parsed = NSDictionary(contentsOf: file)
            #expect(parsed != nil, "\(lproj.lastPathComponent)/Localizable.strings 无法解析（整个语言会在运行时静默失效）")
        }
    }
}
