import AppKit
import SwiftUI

/// The detail pane: everything about one wrap, in three tabs.
struct WrapEditorView: View {

    @ObservedObject var model: LibraryModel
    let wrap: Wrap

    private enum Tab: String, CaseIterable, Identifiable {
        case site = "Site"
        case behavior = "Behaviour"
        case boosts = "Boosts"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .site
    /// Local drafts so typing in a text field doesn't write to disk on every keystroke;
    /// they're committed on submit and on focus loss.
    @State private var nameDraft: String = ""
    @State private var urlDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            Divider()

            switch tab {
            case .site: siteTab
            case .behavior: BehaviorEditorView(model: model, wrap: wrap)
            case .boosts: BoostsTabView(model: model, wrap: wrap)
            }
        }
        .onAppear {
            nameDraft = wrap.name
            urlDraft = wrap.homeURL.absoluteString
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Button {
                model.chooseIconFile(for: wrap)
            } label: {
                Image(nsImage: model.icon(for: wrap))
                    .resizable()
                    .frame(width: 64, height: 64)
                    .cornerRadius(13)
                    .overlay(alignment: .bottomTrailing) {
                        if model.isFetchingIcon {
                            ProgressView().controlSize(.small).padding(3)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("Choose an image file for this app's icon")

            VStack(alignment: .leading, spacing: 3) {
                Text(wrap.name.isEmpty ? "Untitled" : wrap.name)
                    .font(.title2.weight(.semibold))
                Text(wrap.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                statusLine
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Button {
                    model.build(wrap)
                } label: {
                    if model.isBuilding {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(wrap.installedAppPath == nil ? "Build App" : "Rebuild App")
                    }
                }
                .disabled(model.isBuilding)

                if let url = wrap.installedAppURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(20)
    }

    private var statusLine: some View {
        let version = Bundle.main.shortVersionString
        return statusLabel(currentVersion: version)
    }

    @ViewBuilder
    private func statusLabel(currentVersion version: String) -> some View {
        if wrap.installedAppPath == nil {
            Label("Not built yet", systemImage: "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if wrap.hasStaleRuntime(currentVersion: version) {
            Label("Built by Wrapybara \(wrap.installedRuntimeVersion ?? "an older version")"
                  + " — rebuild to update its runtime",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Label("Built with Wrapybara \(version)", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    // MARK: Site tab

    private var siteTab: some View {
        Form {
            Section {
                TextField("Name", text: $nameDraft)
                    .onSubmit(commitName)
                Text("The app's name in the Dock, the menu bar and Finder. Changing it renames "
                     + "the app on the next build.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Address", text: $urlDraft)
                    .onSubmit(commitURL)
                Text("Where the app opens, and what counts as “inside” it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Icon") {
                LabeledContent("Source") {
                    Text(iconSourceDescription)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Fetch from Site") {
                        Task { await model.fetchIcon(for: wrap.id) }
                    }
                    .disabled(model.isFetchingIcon)
                    Button("Choose File…") { model.chooseIconFile(for: wrap) }
                }
            }

            Section("Bundle identifier") {
                Text(wrap.bundleIdentifier)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text("Fixed for the life of the wrap. It keys the app's cookies, logins and "
                     + "Notification Center permission, so changing it would sign you out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // A field that has focus and then loses it (clicking another control) should
        // still commit, not silently discard what was typed.
        .onDisappear {
            commitName()
            commitURL()
        }
    }

    private var iconSourceDescription: String {
        switch wrap.icon.origin {
        case .monogram: return "Generated initials"
        case .pickedFile: return wrap.icon.sourceURL?.lastPathComponent ?? "An image file"
        case .fetchedFromSite: return wrap.icon.sourceURL?.absoluteString ?? "From the site"
        }
    }

    private func commitName() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != wrap.name else { return }
        var updated = wrap
        updated.name = trimmed
        // Keep the monogram in step with a rename; artwork the user chose is left alone.
        if updated.icon.origin == .monogram {
            updated.icon = .monogram(for: trimmed)
        }
        model.update(updated)
    }

    private func commitURL() {
        guard let url = URLNormalizer.url(from: urlDraft) else {
            urlDraft = wrap.homeURL.absoluteString
            return
        }
        guard url != wrap.homeURL else { return }
        var updated = wrap
        updated.homeURL = url
        model.update(updated)
    }
}
