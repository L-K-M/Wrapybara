import AppKit
import SwiftUI

/// Local toolchain setup and Android tradeoffs before choosing an APK destination.
struct AndroidExportView: View {

    @ObservedObject var model: LibraryModel
    @ObservedObject var preferences: Preferences
    let wrap: Wrap
    @Environment(\.dismiss) private var dismiss

    private enum ToolDirectory {
        case sdk
        case javaHome
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Export “\(wrap.name)” for Android")
                .font(.headline)
                .padding(20)

            Divider()

            Form {
                Section("Build tools") {
                    Text(AndroidAPKExporter.androidRequirements)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        TextField("Android SDK", text: $preferences.androidSDKDirectoryPath)
                        Button("Choose…") { chooseDirectory(.sdk) }
                    }

                    HStack {
                        TextField("JDK home", text: $preferences.androidJavaHomePath,
                                  prompt: Text("Automatic"))
                        Button("Choose…") { chooseDirectory(.javaHome) }
                    }
                    Text("For a custom JDK, select its Contents/Home folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("On Android") {
                    Text("Requires Android 8 or later. Transfer the APK to your device "
                         + "and allow installation from the app you use to open it.")
                    Text("Boosts apply to the main page after loading. Before-page scripts "
                         + "are skipped. Rebuild and reinstall to apply edits.")
                    Text("Some sign-ins may not work. Background updates follow Android's limits.")
                    Text("Mac window, tab and user-agent settings do not apply. "
                         + "New-tab links open in this app.")
                    Text("Uploads, camera, microphone and site notifications are unavailable. "
                         + "Downloads open in your browser.")
                }
                .font(.callout)

                Section("Keep your signing key") {
                    Text("Back up Wrapybara's support folder. Losing its Android signing key "
                         + "prevents updates to installed APKs.")
                        .font(.callout)
                    Button("Show Backup Folder") { model.revealAndroidBackupFolder() }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isBuilding)

            Divider()

            HStack {
                if model.isBuilding {
                    ProgressView().controlSize(.small)
                    Text("Building APK…").foregroundStyle(.secondary)
                }

                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export APK…") { model.exportAndroidAPK(for: wrap) }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.isBuilding)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 620)
        .interactiveDismissDisabled(model.isBuilding)
    }

    private func chooseDirectory(_ directory: ToolDirectory) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true

        switch directory {
        case .sdk:
            panel.message = "Choose your Android SDK folder"
            panel.directoryURL = preferences.androidSDKDirectory
        case .javaHome:
            panel.message = "Choose your JDK home folder (Contents/Home)"
            panel.directoryURL = preferences.androidJavaHome
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        switch directory {
        case .sdk: preferences.androidSDKDirectoryPath = url.path
        case .javaHome: preferences.androidJavaHomePath = url.path
        }
    }
}
