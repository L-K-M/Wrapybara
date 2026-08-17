import AppKit
import SwiftUI

/// Wrapybara's own Settings sheet.
struct BuilderSettingsView: View {

    @ObservedObject var model: LibraryModel
    /// Observed explicitly rather than reached through `model`: these controls write to
    /// `Preferences`, and a view that doesn't observe it wouldn't redraw its own edits.
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss

    @State private var identities: [(hash: String, name: String)] = []
    @State private var isToolchainAvailable = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wrapybara Settings")
                .font(.headline)
                .padding(20)

            Divider()

            Form {
                Section("Where apps are built") {
                    LabeledContent("Folder") {
                        HStack {
                            Text(preferences.installDirectoryPath)
                                .lineLimit(1)
                                .truncationMode(.head)
                                .foregroundStyle(.secondary)
                            Button("Choose…", action: chooseInstallDirectory)
                        }
                    }
                    HStack {
                        Button("Use /Applications") {
                            preferences.installDirectoryPath = "/Applications"
                        }
                        Button("Use ~/Applications") {
                            preferences.installDirectoryPath = Preferences
                                .userApplicationsDirectory.path
                        }
                    }
                    if !FileManager.default.isWritableFile(atPath: preferences.installDirectoryPath) {
                        Label("Wrapybara can't write there.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Signing") {
                    Picker("Sign apps with", selection: signingBinding) {
                        Text("Ad-hoc (no certificate)").tag(CodeSigner.adHocIdentity)
                        ForEach(identities, id: \.hash) { identity in
                            Text(identity.name).tag(identity.name)
                        }
                    }
                    if preferences.isSigningAdHoc {
                        Text("Ad-hoc signing needs nothing and is enough for the app to launch. "
                             + "macOS still shows Gatekeeper's first-run warning; right-click → "
                             + "Open once clears it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Signed with your Developer ID, so no Gatekeeper warning. Apps built "
                             + "this way are still not notarized.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !isToolchainAvailable {
                        Label("The Xcode Command Line Tools aren't installed, so Wrapybara can't "
                              + "sign — and macOS won't run an unsigned app on Apple Silicon.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Install Command Line Tools…") {
                            _ = try? ProcessRunner.run(CodeSigner.xcodeSelectPath,
                                                       arguments: ["--install"], timeout: 10)
                        }
                    }
                }

                Section("Icons") {
                    Picker("Icon style", selection: Binding(
                        get: { preferences.iconStyle },
                        set: { preferences.iconStyle = $0 })) {
                            ForEach(IconComposer.Style.allCases) { Text($0.displayName).tag($0) }
                        }
                    Text("A site's artwork is drawn for a browser tab or an iOS home screen. "
                         + "Composing it onto a Mac-proportioned rounded plate is what keeps it "
                         + "from sitting in the Dock as a hard square among rounded ones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("After building") {
                    Toggle("Launch the app", isOn: Binding(
                        get: { preferences.launchAfterBuild },
                        set: { preferences.launchAfterBuild = $0 }))
                    Toggle("Reveal it in Finder", isOn: Binding(
                        get: { preferences.revealAfterBuild },
                        set: { preferences.revealAfterBuild = $0 }))
                }

                Section("Imported boosts") {
                    Toggle("Hold back JavaScript until I trust it", isOn: Binding(
                        get: { preferences.warnsBeforeTrustingImportedScripts },
                        set: { preferences.warnsBeforeTrustingImportedScripts = $0 }))
                    Text("An imported boost's script runs in the page, inside whatever session "
                         + "that app is signed into. Leaving this on means you read it first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 560, height: 620)
        .task {
            // Both probes shell out (`security find-identity`, `xcode-select -p`)
            // through ProcessRunner, which blocks the calling thread until the
            // tool exits — so they run off the main actor, and their results hop
            // back. Done once when the sheet opens rather than on every redraw.
            let probed = await Task.detached {
                (identities: CodeSigner.availableSigningIdentities(),
                 toolchain: CodeSigner.isAvailable)
            }.value
            await MainActor.run {
                identities = probed.identities
                isToolchainAvailable = probed.toolchain
            }
        }
    }

    private var signingBinding: Binding<String> {
        Binding(get: { preferences.signingIdentity },
                set: { preferences.signingIdentity = $0 })
    }

    private func chooseInstallDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose where Wrapybara writes the apps it builds"
        panel.directoryURL = preferences.installDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.installDirectoryPath = url.path
    }
}
