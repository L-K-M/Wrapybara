import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The boost-editing half of `LibraryModel`: the element picker and boost files.
///
/// Split into its own file to keep `LibraryModel` about wraps, and because these two
/// are the parts that touch the world (a live web view, and files the user can share).
extension LibraryModel {

    // MARK: Element picker

    /// Runs the picker in the preview and appends whatever the user chooses.
    func beginPickingElement(for boost: Boost, in wrap: Wrap) {
        guard let preview = previewController, !isPickingElement else { return }
        isPickingElement = true
        preview.beginPicking { [weak self] selector in
            guard let self else { return }
            self.isPickingElement = false
            let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }   // cancelled

            // Re-read the boost: the user may have edited something else while the picker
            // was up, and writing back a stale copy would undo it.
            guard let current = self.currentVersion(of: boost, in: wrap) else { return }
            guard !current.zapSelectors.contains(trimmed) else { return }
            var updated = current
            updated.zapSelectors.append(trimmed)
            self.updateBoost(updated, in: wrap)
        }
    }

    /// The stored copy of `boost`, wherever it lives.
    func currentVersion(of boost: Boost, in wrap: Wrap) -> Boost? {
        if let fresh = store.library.wrap(id: wrap.id)?.boosts.first(where: { $0.id == boost.id }) {
            return fresh
        }
        return store.library.sharedBoosts.first { $0.id == boost.id }
    }

    // MARK: Presets

    /// True when a boost with the same name *and* functional payload (theme, CSS)
    /// is already on the shared shelf — the one home of the "preset already
    /// added" rule. Notes are deliberately excluded: they're the most likely
    /// thing a user edits after adding, and a trimmed note shouldn't re-enable
    /// a preset that's functionally already there.
    func isPresetOnShelf(_ boost: Boost) -> Bool {
        store.library.sharedBoosts.contains {
            $0.name == boost.name && $0.css == boost.css && $0.theme == boost.theme
        }
    }

    /// Adds a ready-made boost to the shared shelf, selected and switched on for no
    /// wrap yet — exactly like an import, minus the file.
    func addPreset(_ boost: Boost) {
        // The same preset twice is a no-op. The model owns this rule rather than
        // the menu's `disabled`, so any caller gets it.
        guard !isPresetOnShelf(boost) else { return }
        var copy = boost
        // A fresh id, so re-adding a preset after renaming (or deleting) the first
        // copy can never collide with an id that already lives on the shelf.
        copy.id = UUID()
        store.addSharedBoost(copy)
        selectedBoostID = copy.id
    }

    // MARK: Boost files

    /// The extension for an exported boost.
    static let boostFileExtension = "wrapyboost"

    /// Writes `boost` to a file the user can hand to someone else.
    func exportBoost(_ boost: Boost) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(boost.name).\(Self.boostFileExtension)"
        panel.message = "Export “\(boost.name)”"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Export with the trust flag cleared. A boost file is a thing that travels,
            // and its script must arrive inert on the other side — whoever imports it
            // has to read it and say yes, not inherit our decision.
            var shareable = boost
            shareable.isJavaScriptTrusted = false
            let data = try JSONFileStore.encoder.encode(shareable)
            try data.write(to: url, options: [.atomic])
        } catch {
            alert = AlertContent(title: "Couldn't export the boost",
                                 message: error.localizedDescription, isError: true)
        }
    }

    /// Asks for boost files and imports them onto the shared shelf.
    func importBoostsFromPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose boost files to import"
        if let type = UTType(filenameExtension: Self.boostFileExtension) {
            panel.allowedContentTypes = [type, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        guard panel.runModal() == .OK else { return }
        importBoosts(from: panel.urls)
    }

    /// Imports boost files, reporting what happened.
    ///
    /// Imported boosts land on the **shared shelf** rather than in a wrap: a boost worth
    /// sharing is usually written against a site, not against one person's app, and the
    /// shelf is where a boost gets switched on per wrap.
    func importBoosts(from urls: [URL]) {
        var imported: [String] = []
        var failures: [String] = []
        var carriedScripts = 0

        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                var boost = try JSONFileStore.decoder.decode(Boost.self, from: data)
                // A fresh id, so importing the same file twice gives two boosts rather
                // than one that silently overwrites the other.
                boost.id = UUID()
                // `Boost.init(from:)` already defaults the trust flag to false on decode;
                // this is belt-and-braces against a file that sets it to true.
                if !boost.javaScript.isEmpty {
                    boost.isJavaScriptTrusted = false
                    carriedScripts += 1
                }
                boost.isEnabled = false   // arrive switched off; the user turns it on
                store.addSharedBoost(boost)
                imported.append(boost.name)
                selectedBoostID = boost.id
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !imported.isEmpty || !failures.isEmpty else { return }

        var message = imported.isEmpty ? "" :
            "Added to Shared Boosts, switched off: " + imported.joined(separator: ", ")
        if carriedScripts > 0 {
            if !message.isEmpty { message += "\n\n" }
            message += carriedScripts == 1
                ? "One of them carries JavaScript. It won't run until you read it and trust it."
                : "\(carriedScripts) of them carry JavaScript. Those scripts won't run until you "
                    + "read them and trust them."
        }
        if !failures.isEmpty {
            if !message.isEmpty { message += "\n\n" }
            message += "Couldn't read:\n" + failures.joined(separator: "\n")
        }
        alert = AlertContent(title: imported.isEmpty ? "Nothing imported"
                             : "Imported \(imported.count) boost(s)",
                             message: message, isError: !failures.isEmpty)
    }
}
