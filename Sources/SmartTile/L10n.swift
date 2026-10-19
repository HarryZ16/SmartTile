import Foundation

// Localization.
//
// User-facing strings are looked up in Resources/<lang>.lproj/Localizable.strings,
// which build.sh copies into SmartTile.app. The English text itself is the key, so
// English is also the fallback (e.g. when running via `swift run` without a bundle).
// macOS picks the language from the system settings, including the per-app language
// in System Settings › General › Language & Region › Applications.

/// Localized string for `key`.
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Localized format string for `key`, filled with `args` (use %d / %@ placeholders).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: args)
}
