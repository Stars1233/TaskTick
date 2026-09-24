import Testing
import AppKit
import Foundation
@testable import TaskTickApp

/// The editor's tab bar folds tabs into a "»" overflow menu when they don't fit
/// — silently, and the `.contentSize` window can't be dragged wider. The Push
/// tab (issue #55) made six tabs; these read every language's real titles off
/// disk so a long translation fails here instead of in a user's screenshot.
/// Mirrors `SettingsWindowWidthTests`.
@Suite("Task editor window width")
@MainActor
struct EditorWindowWidthTests {

    private var localizationDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TaskTickCore/Localization")
    }

    /// (language, titles) for every shipped `.lproj`, in tab-bar order.
    private func titlesPerLanguage() throws -> [(String, [String])] {
        let lprojs = try FileManager.default
            .contentsOfDirectory(at: localizationDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try lprojs.map { lproj in
            let file = lproj.appendingPathComponent("Localizable.strings")
            let table = try #require(NSDictionary(contentsOf: file) as? [String: String],
                                     "\(lproj.lastPathComponent) 解析失败")
            let titles = try TaskEditorView.Tab.allCases.map { tab in
                try #require(table[tab.rawValue],
                             "\(lproj.lastPathComponent) 缺少 tab 文案 \(tab.rawValue)")
            }
            return (lproj.deletingPathExtension().lastPathComponent, titles)
        }
    }

    @Test("每种语言的 6 个 tab 标题都存在（缺失会让宽度按 key 本身计算）")
    func everyLanguageHasEveryTabTitle() throws {
        let all = try titlesPerLanguage()
        #expect(!all.isEmpty, "未找到任何 .lproj，路径推导可能失效")
        for (lang, titles) in all {
            #expect(titles.count == TaskEditorView.Tab.allCases.count, "\(lang) tab 文案数量不符")
            #expect(titles.allSatisfy { !$0.isEmpty }, "\(lang) 有空的 tab 文案")
        }
    }

    @Test("每种语言算出的窗口宽度都装得下居中的 tab 栏和左侧红绿灯")
    func widthFitsEveryLanguage() throws {
        for (lang, titles) in try titlesPerLanguage() {
            let bar = TaskEditorView.tabBarWidth(titles: titles)
            let width = TaskEditorView.windowWidth(titles: titles, screenWidth: 3000)
            #expect(width >= bar + 2 * TaskEditorView.titleBarReserve,
                    "\(lang): 窗口 \(width)pt 装不下 \(bar)pt 的 tab 栏，会折成 »")
        }
    }

    @Test("装得下的语言保持 720pt 原有比例")
    func shortLanguagesKeepTheFamiliarWidth() throws {
        let byLang = Dictionary(uniqueKeysWithValues: try titlesPerLanguage())
        for lang in ["zh-Hans", "zh-Hant", "ja", "ko", "en", "id"] {
            let titles = try #require(byLang[lang])
            #expect(TaskEditorView.windowWidth(titles: titles, screenWidth: 3000) == 720,
                    "\(lang) 本来就装得下，不该被撑宽")
        }
    }

    @Test("长语言只加必要的宽度，不会变成怪物窗口")
    func longLanguagesStayReasonable() throws {
        for (lang, titles) in try titlesPerLanguage() {
            let width = TaskEditorView.windowWidth(titles: titles, screenWidth: 3000)
            #expect(width <= 820, "\(lang) 撑到 \(width)pt，翻译可能过长，需要缩短 tab 标题")
        }
    }

    @Test("窄屏下不会开出比屏幕还宽的窗口")
    func neverExceedsTheScreen() {
        let monster = Array(repeating: String(repeating: "W", count: 40), count: 6)
        #expect(TaskEditorView.windowWidth(titles: monster, screenWidth: 1000) == 920)
    }

    @Test("屏幕比 720 还窄时仍不塌到 720 以下")
    func neverShrinksBelowTheBaseline() {
        #expect(TaskEditorView.windowWidth(titles: ["A", "B"], screenWidth: 400) == 720)
    }
}
