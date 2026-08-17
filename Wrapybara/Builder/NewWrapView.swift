import SwiftUI

/// The "wrap a site" sheet.
///
/// One field that matters. The name is optional because the fetcher can usually read a
/// better one out of the site's own web app manifest than anyone would type.
struct NewWrapView: View {

    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss

    @State private var address = ""
    @State private var name = ""

    private var normalizedURL: URL? { URLNormalizer.url(from: address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Wrap a Site")
                    .font(.headline)
                Text("Wrapybara builds it into a real Mac app: its own icon, menu bar, tabs, "
                     + "Dock tile and login session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(20)

            Divider()

            Form {
                TextField("Address", text: $address, prompt: Text("claude.ai"))
                    .onSubmit(create)
                TextField("Name", text: $name, prompt: Text(suggestedName))
                    .onSubmit(create)
                if !address.isEmpty, normalizedURL == nil {
                    Label("That doesn't look like a web address.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Text("The app lands in \(model.preferences.installDirectory.lastPathComponent).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedURL == nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 480)
    }

    /// What the name field will use if left blank — shown as its placeholder, so the
    /// user can see the guess before accepting it.
    private var suggestedName: String {
        guard let url = normalizedURL else { return "From the site" }
        let guess = URLNormalizer.suggestedName(for: url)
        return guess.isEmpty ? "From the site" : guess
    }

    private func create() {
        guard normalizedURL != nil else { return }
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        model.createWrap(from: address, name: typed.isEmpty ? nil : typed)
        dismiss()
    }
}
