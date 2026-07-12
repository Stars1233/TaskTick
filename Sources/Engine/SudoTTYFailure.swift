import Foundation

/// Detects the "sudo has no terminal to prompt for a password" failure in a
/// run's stderr, so log views can show a targeted fix hint (issue #40).
enum SudoTTYFailure {
    /// Both known sudo wordings ship untranslated on macOS, so plain
    /// substring checks are safe. Requiring "sudo" alongside the phrase
    /// avoids false positives from other tools echoing similar text.
    static func matches(stderr: String?) -> Bool {
        guard let stderr, stderr.contains("sudo") else { return false }
        return stderr.contains("a terminal is required to read the password")
            || stderr.contains("no tty present and no askpass")
    }
}
