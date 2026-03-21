import Foundation
import SwiftUI

/// Supported app languages.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case fr = "fr"
    case de = "de"
    case it = "it"
    case es = "es"
    case ru = "ru"
    case id = "id"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System / 跟随系统"
        case .zhHans: "简体中文"
        case .zhHant: "繁體中文"
        case .en: "English"
        case .ja: "日本語"
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .it: "Italiano"
        case .es: "Español"
        case .ru: "Русский"
        case .id: "Bahasa Indonesia"
        }
    }

    /// Resolve the actual language code (for .system, detect from system preferences).
    var resolvedCode: String {
        switch self {
        case .system:
            for lang in Locale.preferredLanguages {
                // Traditional Chinese detection (zh-Hant, zh-TW, zh-HK)
                if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-TW") || lang.hasPrefix("zh-HK") {
                    return "zh-Hant"
                }
                if lang.hasPrefix("zh") { return "zh-Hans" }
                if lang.hasPrefix("en") { return "en" }
                if lang.hasPrefix("ja") { return "ja" }
                if lang.hasPrefix("ko") { return "ko" }
                if lang.hasPrefix("fr") { return "fr" }
                if lang.hasPrefix("de") { return "de" }
                if lang.hasPrefix("it") { return "it" }
                if lang.hasPrefix("es") { return "es" }
                if lang.hasPrefix("ru") { return "ru" }
                if lang.hasPrefix("id") || lang.hasPrefix("ms") { return "id" }
            }
            return "en"
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ja: return "ja"
        case .ko: return "ko"
        case .fr: return "fr"
        case .de: return "de"
        case .it: return "it"
        case .es: return "es"
        case .ru: return "ru"
        case .id: return "id"
        }
    }
}

/// Observable language manager that triggers SwiftUI re-renders on language change.
@MainActor
final class LanguageManager: ObservableObject {
    static let shared = LanguageManager()

    /// Bump this to force SwiftUI views to re-compute L10n.tr() calls.
    @Published var revision: Int = 0

    @Published var current: AppLanguage {
        didSet {
            UserDefaults.standard.set(current.rawValue, forKey: "appLanguage")
            L10n.reloadBundle(for: current)
            revision += 1
        }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let lang = AppLanguage(rawValue: saved) ?? .system
        self.current = lang
        L10n.reloadBundle(for: lang)
    }
}

/// Localization helper.
///
/// SPM `.process()` may lowercase directory names (e.g. `zh-Hans.lproj` -> `zh-hans.lproj`),
/// so we do a case-insensitive search for the correct `.lproj` bundle.
enum L10n {
    /// Safe resource bundle lookup — searches multiple locations, never crashes.
    private static let _resourceBundle: Bundle = {
        let bundleName = "TaskTick_TaskTick.bundle"
        let candidates: [URL] = [
            // 1. App root (alongside Contents/) — standard SPM placement
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
            // 2. Inside Contents/Resources/
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(bundleName)"),
            // 3. Same directory as the executable
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
            // 4. Two levels up from executable (Contents/MacOS/../../)
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(bundleName),
        ].compactMap { $0 }

        for url in candidates {
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }

        // Last resort: try SPM-generated Bundle.module (may fatalError, but we tried everything else)
        return Bundle.module
    }()

    nonisolated(unsafe) private static var _bundle: Bundle = {
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let lang = AppLanguage(rawValue: saved) ?? .system
        return findBundle(for: lang.resolvedCode) ?? _resourceBundle
    }()

    static func reloadBundle(for language: AppLanguage) {
        let code = language.resolvedCode
        _bundle = findBundle(for: code) ?? _resourceBundle
    }

    /// Case-insensitive search for .lproj bundle inside the resource bundle
    private static func findBundle(for code: String) -> Bundle? {
        // Try exact match first
        if let path = _resourceBundle.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }

        // Fallback: scan the bundle directory for case-insensitive match
        let target = "\(code).lproj".lowercased()
        let bundleURL = _resourceBundle.bundleURL
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: bundleURL, includingPropertiesForKeys: nil
        ) {
            for url in contents {
                if url.lastPathComponent.lowercased() == target {
                    return Bundle(url: url)
                }
            }
        }

        return nil
    }

    static func tr(_ key: String) -> String {
        NSLocalizedString(key, bundle: _bundle, comment: "")
    }

    static func tr(_ key: String, _ args: any CVarArg...) -> String {
        let format = NSLocalizedString(key, bundle: _bundle, comment: "")
        return String(format: format, arguments: args)
    }
}

/// View modifier that forces re-render when language changes.
struct LocalizedView: ViewModifier {
    @ObservedObject private var lm = LanguageManager.shared

    func body(content: Content) -> some View {
        content
            .id(lm.revision) // Force rebuild entire view tree on language change
    }
}

extension View {
    /// Apply this to top-level views to make them respond to language changes.
    func localized() -> some View {
        modifier(LocalizedView())
    }
}
