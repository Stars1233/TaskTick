import Foundation
import SwiftUI

/// Supported app languages.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system = "system"
    case en = "en"
    case zhHans = "zh-Hans"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System / 跟随系统"
        case .en: "English"
        case .zhHans: "简体中文"
        }
    }

    /// Resolve the actual language code (for .system, detect from system preferences).
    var resolvedCode: String {
        switch self {
        case .system:
            for lang in Locale.preferredLanguages {
                if lang.hasPrefix("zh") { return "zh-Hans" }
                if lang.hasPrefix("en") { return "en" }
            }
            return "en"
        case .en: return "en"
        case .zhHans: return "zh-Hans"
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
    nonisolated(unsafe) private static var _bundle: Bundle = {
        // On first access, try to load the system-preferred language bundle
        let saved = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let lang = AppLanguage(rawValue: saved) ?? .system
        return findBundle(for: lang.resolvedCode) ?? Bundle.module
    }()

    static func reloadBundle(for language: AppLanguage) {
        let code = language.resolvedCode
        _bundle = findBundle(for: code) ?? Bundle.module
    }

    /// Case-insensitive search for .lproj bundle inside Bundle.module
    private static func findBundle(for code: String) -> Bundle? {
        // Try exact match first
        if let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) {
            return b
        }

        // Fallback: scan the bundle directory for case-insensitive match
        let target = "\(code).lproj".lowercased()
        let bundleURL = Bundle.module.bundleURL
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
