import AppKit
import SwiftUI

/// The Boosts tab: this wrap's boosts, the shared shelf, and the editor for whichever
/// one is selected.
struct BoostsTabView: View {

    @ObservedObject var model: LibraryModel
    let wrap: Wrap

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 340)
            editor
                .frame(minWidth: 420)
        }
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedBoostID) {
                Section("This app") {
                    if wrap.boosts.isEmpty {
                        Text("None yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(wrap.boosts) { boost in
                        BoostRow(boost: boost, isShared: false)
                            .tag(boost.id)
                            .contextMenu {
                                Button("Duplicate") { duplicate(boost) }
                                Button("Move to Shared Boosts") { model.shareBoost(boost, from: wrap) }
                                Button("Export…") { model.exportBoost(boost) }
                                Divider()
                                Button("Delete") { model.deleteBoost(boost, from: wrap) }
                            }
                    }
                }

                Section("Shared boosts") {
                    if model.store.library.sharedBoosts.isEmpty {
                        Text("Shared boosts are switched on per app — add a preset or import "
                             + "a .wrapyboost file.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.store.library.sharedBoosts) { boost in
                        HStack(spacing: 6) {
                            Toggle("", isOn: sharedBinding(for: boost))
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                                .help("Use this boost in \(wrap.name)")
                            BoostRow(boost: boost, isShared: true)
                        }
                        .tag(boost.id)
                        .contextMenu {
                            Button("Export…") { model.exportBoost(boost) }
                            Divider()
                            Button("Delete Everywhere") {
                                model.store.removeSharedBoost(id: boost.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack(spacing: 6) {
                Button { model.addBoost(to: wrap) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New boost for this app")
                Button {
                    guard let boost = model.selectedBoost else { return }
                    model.deleteBoost(boost, from: wrap)
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedBoost == nil)
                Menu {
                    ForEach(PresetBoosts.all) { preset in
                        Button(preset.name) { model.addPreset(preset) }
                            .disabled(model.store.library.sharedBoosts.contains {
                                $0.name == preset.name
                            })
                    }
                } label: {
                    Image(systemName: "sparkles")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a ready-made boost to the shared shelf")
                Spacer()
                Button { model.importBoostsFromPanel() } label: { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Import a boost file")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
        }
    }

    private func sharedBinding(for boost: Boost) -> Binding<Bool> {
        Binding(
            get: { wrap.enabledSharedBoostIDs.contains(boost.id) },
            set: { model.setSharedBoost(boost.id, enabled: $0, in: wrap) })
    }

    private func duplicate(_ boost: Boost) {
        var copy = boost
        copy.id = UUID()
        copy.name = boost.name + " Copy"
        var updated = wrap
        updated.boosts.append(copy)
        model.update(updated)
        model.selectedBoostID = copy.id
    }

    // MARK: Editor

    @ViewBuilder
    private var editor: some View {
        if let boost = model.selectedBoost {
            BoostEditorView(model: model, wrap: wrap, boost: boost)
                .id(boost.id)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("Select a boost, or make one")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("A boost restyles the site inside this app: colours, type, hidden elements, "
                     + "your own CSS and JavaScript.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Row

private struct BoostRow: View {
    let boost: Boost
    let isShared: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if !boost.isEnabled {
                    Image(systemName: "pause.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Switched off")
                }
                Text(boost.name).lineLimit(1)
                if boost.hasUntrustedJavaScript {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("This boost's JavaScript is held back until you trust it")
                }
            }
            Text("\(boost.match.summary) · \(boost.contentsSummary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
    }
}
