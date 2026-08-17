import Foundation

/// Folds a wrap's display name into something safe to use as a file name.
///
/// The generated bundle is `<name>.app` on a real file system, and the name comes
/// from a text field, so this has to hold against `/`, `:` (which Finder shows as
/// `/`), leading dots, control characters, the Windows-reserved device names that
/// break on SMB shares, and the empty string.
enum AppNameSanitizer {

    /// Characters that can't appear in a path component on macOS or on a network
    /// volume it might be copied to.
    static let forbidden: Set<Character> = [
        "/", ":", "\\", "*", "?", "\"", "<", ">", "|", "\0",
    ]

    /// Names that are device files on Windows and so break SMB/exFAT volumes.
    static let reservedNames: Set<String> = [
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    ]

    /// The longest name we'll produce. HFS+/APFS allow 255 UTF-16 code units per
    /// component; leaving room for `.app` and a `-2` disambiguating suffix keeps
    /// every derived path legal.
    static let maxLength = 200

    /// The fall-back when the name sanitises down to nothing.
    static let fallback = "Web App"

    /// A file-name-safe version of `name`, without the `.app` extension.
    static func fileName(for name: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in name {
            if character.isNewline || isControl(character) { continue }
            if forbidden.contains(character) {
                // Collapse a forbidden character into a space rather than deleting
                // it, so "Mail/Calendar" reads as two words instead of one.
                if !lastWasSpace { result.append(" ") ; lastWasSpace = true }
                continue
            }
            result.append(character)
            lastWasSpace = character == " "
        }

        result = result.trimmingCharacters(in: .whitespaces)
        // A leading dot would make the app invisible in Finder.
        while result.hasPrefix(".") { result.removeFirst() }
        // A trailing dot or space is legal on APFS but confuses archive tools.
        while result.hasSuffix(".") || result.hasSuffix(" ") { result.removeLast() }

        if result.count > maxLength {
            result = String(result.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        }
        guard !result.isEmpty else { return fallback }
        if reservedNames.contains(result.uppercased()) { return result + " App" }
        return result
    }

    /// Whether `character` is a single control scalar. `CharacterSet` rather than
    /// `Unicode.Scalar.Properties` so the check reads the same way as the one in
    /// `UpdateDownloader.sanitizedFileName`.
    static func isControl(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first
        else { return false }
        return CharacterSet.controlCharacters.contains(scalar)
    }

    /// A name not already taken in `existing`, by appending ` 2`, ` 3`, … Used when
    /// two wraps want the same `.app` file name.
    static func uniqueFileName(for name: String, avoiding existing: Set<String>) -> String {
        let base = fileName(for: name)
        guard existing.contains(base) else { return base }
        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !existing.contains(candidate) { return candidate }
        }
        return "\(base) \(UUID().uuidString.prefix(8))"
    }
}
