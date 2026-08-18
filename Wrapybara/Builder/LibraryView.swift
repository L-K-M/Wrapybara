import AppKit
import SwiftUI

/// Wrapybara's window: wraps on the left, the selected wrap's editor on the right.
struct LibraryView: View {

    @ObservedObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            detail
        }
        .frame(minWidth: 860, minHeight: 540)
        // SwiftUI's own `sheet(item:)` and `alert(_:isPresented:presenting:)` —
        // deliberately not wrapped in convenience helpers, which would be ambiguous
        // against the framework's overloads.
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newWrap:
                NewWrapView(model: model)
            case .settings:
                BuilderSettingsView(model: model, preferences: model.preferences)
            }
        }
        .alert(Text(model.alert?.title ?? ""),
               isPresented: Binding(get: { model.alert != nil },
                                    set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { content in
            Text(content.message)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedWrapID) {
                Section("Wraps") {
                    ForEach(model.wraps) { wrap in
                        WrapRow(wrap: wrap, icon: model.icon(for: wrap),
                                isStale: wrap.hasStaleRuntime(
                                    currentVersion: Bundle.main.shortVersionString))
                            .tag(wrap.id)
                            .contextMenu { contextMenu(for: wrap) }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            footer
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                model.sheet = .newWrap
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("Wrap a new site")

            Button {
                guard let wrap = model.selectedWrap else { return }
                model.deleteWrap(wrap)
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(model.selectedWrap == nil)
            .help("Remove the selected wrap from the library")

            Spacer()

            if model.staleWrapCount > 0 {
                Button("Rebuild \(model.staleWrapCount)") { model.refreshStaleRuntimes() }
                    .buttonStyle(.borderless)
                    .help("These apps were built by an older Wrapybara. Rebuilding updates the "
                          + "runtime inside them.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func contextMenu(for wrap: Wrap) -> some View {
        Group {
            Button("Build App") { model.build(wrap) }
            if let url = wrap.installedAppURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Move App to Trash") { model.trashApp(for: wrap) }
            }
            Divider()
            Button("Refresh Icon from Site") {
                Task { await model.fetchIcon(for: wrap.id) }
            }
            Divider()
            Button("Remove from Library") { model.deleteWrap(wrap) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let wrap = model.selectedWrap {
            WrapEditorView(model: model, wrap: wrap)
                // Re-create the editor when the selection changes, so its local
                // draft state can't leak from one wrap into another.
                .id(wrap.id)
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.on.square.dashed")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No wraps yet")
                .font(.title3.weight(.medium))
            Text("Wrap a site and Wrapybara builds it into a real Mac app —\nwith its own icon, "
                 + "menu bar, tabs and Dock tile.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Wrap a Site…") { model.sheet = .newWrap }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Row

private struct WrapRow: View {
    let wrap: Wrap
    let icon: NSImage
    let isStale: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 26, height: 26)
                .cornerRadius(5)
            VStack(alignment: .leading, spacing: 1) {
                Text(wrap.name.isEmpty ? "Untitled" : wrap.name)
                    .lineLimit(1)
                Text(URLNormalizer.displayString(for: wrap.homeURL, maxLength: 34))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if isStale {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Built by an older Wrapybara")
            } else if wrap.installedAppPath != nil {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .help("Built")
            }
        }
        .padding(.vertical, 2)
    }
}
