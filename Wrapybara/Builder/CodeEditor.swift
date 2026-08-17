import SwiftUI

/// A plain monospaced text box for the CSS and JavaScript fields.
///
/// No syntax highlighting: doing it properly means a tokenizer per language and a
/// custom `NSTextStorage`, and doing it badly is worse than not doing it. What actually
/// matters for editing a dozen lines of CSS is a monospaced font, no smart quotes
/// (which silently break a JavaScript string), and no automatic dash substitution
/// (which silently breaks a CSS property name).
struct CodeEditor: View {

    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.callout, design: .monospaced))
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            // `TextEditor` inherits the system's smart-substitution defaults, which turn
            // `"` into `"` and `--` into an en dash. Both would corrupt code silently.
            .onAppear(perform: Self.disableSmartSubstitutions)
    }

    /// Turns off the text system's automatic substitutions for the whole process.
    ///
    /// SwiftUI's `TextEditor` exposes no hook for this, and the substitutions are read
    /// from `UserDefaults` when a text view is created, so setting them in this app's
    /// own domain is the available lever. Wrapybara has no prose fields where smart
    /// quotes would be wanted, so the blast radius is nil.
    static func disableSmartSubstitutions() {
        let defaults = UserDefaults.standard
        for key in ["NSAutomaticQuoteSubstitutionEnabled",
                    "NSAutomaticDashSubstitutionEnabled",
                    "NSAutomaticTextReplacementEnabled",
                    "NSAutomaticSpellingCorrectionEnabled"] {
            defaults.set(false, forKey: key)
        }
    }
}
