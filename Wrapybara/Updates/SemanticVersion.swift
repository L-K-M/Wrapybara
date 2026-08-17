import Foundation

/// A lightweight semantic-version value for comparing an app's version against a
/// release tag. Parses the leading `major[.minor[.patch[.…]]]` number from strings
/// like `"1.2.3"`, `"v1.2.3"`, or `"1.4.0-beta.2"`, ignoring any build-metadata
/// suffix and treating a pre-release as sorting *below* its final release
/// (`1.2.0-beta < 1.2.0`).
///
/// Reusable across apps — depends only on Foundation.
struct SemanticVersion: Comparable, Equatable, CustomStringConvertible {

    /// The dot-separated numeric components (e.g. `[1, 2, 3]`).
    let components: [Int]
    /// The pre-release identifier (the part after `-`), or `nil` for a final release.
    let prerelease: String?
    /// The original (trimmed) string, kept for display.
    let original: String

    static let zero = SemanticVersion("0")!

    /// Parses `raw`, returning `nil` if it has no leading numeric version.
    init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var s = trimmed
        if let first = s.first, first == "v" || first == "V" { s.removeFirst() }
        // Drop build metadata (`+…`), then split off a pre-release (`-…`).
        s = s.split(separator: "+", maxSplits: 1).first.map(String.init) ?? s
        let dashSplit = s.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numberPart = dashSplit.first.map(String.init) ?? s
        let pre = dashSplit.count > 1 ? String(dashSplit[1]) : nil

        let numberIdentifiers = numberPart.split(separator: ".", omittingEmptySubsequences: false)
        guard !numberIdentifiers.contains(where: { Self.hasInvalidNumericLeadingZero($0) }) else { return nil }
        let parsed = numberIdentifiers.map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }

        if let pre {
            let identifiers = pre.split(separator: ".", omittingEmptySubsequences: false)
            guard !pre.isEmpty,
                  !identifiers.contains(where: {
                      $0.isEmpty || !$0.allSatisfy(Self.isAllowedPrereleaseCharacter)
                          || Self.hasInvalidNumericLeadingZero($0)
                  })
            else { return nil }
        }

        self.components = parsed.compactMap { $0 }
        self.prerelease = (pre?.isEmpty == false) ? pre : nil
        self.original = trimmed
    }

    var description: String { original }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        // Compare numeric components, padding the shorter with zeros (1.2 == 1.2.0).
        let count = max(lhs.components.count, rhs.components.count)
        for i in 0..<count {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        // Equal numbers: a pre-release is older than the final release.
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _?):  return false   // final > pre-release
        case (_?, nil):  return true    // pre-release < final
        case let (l?, r?): return comparePrerelease(l, r) == .orderedAscending
        }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lParts = lhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rParts = rhs.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let count = max(lParts.count, rParts.count)
        for index in 0..<count {
            guard index < lParts.count else { return .orderedAscending }
            guard index < rParts.count else { return .orderedDescending }
            let l = lParts[index]
            let r = rParts[index]
            if l == r { continue }
            let lIsNumeric = isASCIINumeric(l)
            let rIsNumeric = isASCIINumeric(r)
            switch (lIsNumeric, rIsNumeric) {
            case (true, true):
                if l.count != r.count { return l.count < r.count ? .orderedAscending : .orderedDescending }
                return l.lexicographicallyPrecedes(r) ? .orderedAscending : .orderedDescending
            case (true, false):
                return .orderedAscending
            case (false, true):
                return .orderedDescending
            case (false, false):
                let result = l.compare(r)
                if result != .orderedSame { return result }
            }
        }
        return .orderedSame
    }

    private static func isASCIINumeric<S: StringProtocol>(_ value: S) -> Bool {
        !value.isEmpty && value.allSatisfy {
            guard let scalar = $0.unicodeScalars.first, $0.unicodeScalars.count == 1 else { return false }
            return scalar.value >= 48 && scalar.value <= 57
        }
    }

    private static func hasInvalidNumericLeadingZero<S: StringProtocol>(_ value: S) -> Bool {
        value.count > 1 && value.first == "0" && isASCIINumeric(value)
    }

    private static func isAllowedPrereleaseCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1 else { return false }
        let value = scalar.value
        return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
            || (value >= 97 && value <= 122) || value == 45
    }

    /// Semantic equality (so `1.2` equals `1.2.0`), independent of the raw string.
    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}
