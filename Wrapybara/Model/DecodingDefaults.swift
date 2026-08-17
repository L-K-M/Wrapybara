import Foundation

extension KeyedDecodingContainer {
    /// Decodes `key` if it is present and non-null, otherwise returns `fallback`.
    ///
    /// Every stored Wrapybara type decodes through this instead of the synthesized
    /// `init(from:)`, for one reason: a wrap config is a long-lived file on disk (and
    /// a *baked-in* copy inside every generated `.app`). A synthesized decoder throws
    /// the moment the format gains a property, which would make a Wrapybara upgrade
    /// orphan every app the previous version built. With this, a missing key is just
    /// that key's default.
    ///
    /// It deliberately swallows type mismatches as well as absence: these files are
    /// hand-editable, and one mistyped value should degrade to the default for that
    /// one field rather than fail the whole load and lose the user's other work.
    /// Structural breakage is handled by `formatVersion` instead — see
    /// `WrapConfiguration`.
    func value<T: Decodable>(_ key: Key, or fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    /// The optional-valued sibling of `value(_:or:)`: a missing key, an explicit
    /// `null`, and an unreadable value all decode to `nil`.
    ///
    /// This exists rather than calling `value(key, or: String?.none)`, which would
    /// ask for `Optional<String>` as the decoded type and lean on double-optional
    /// flattening to mean the right thing. Spelling it out keeps the intent legible.
    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
