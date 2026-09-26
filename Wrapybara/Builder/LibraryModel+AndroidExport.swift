import AppKit
import UniformTypeIdentifiers

extension LibraryModel {

    private static let androidIconPixels = 512
    private static let androidPackageExtension = "apk"

    @MainActor
    func exportAndroidAPK(for wrap: Wrap) {
        guard !isBuilding else { return }

        let panel = NSSavePanel()
        panel.title = "Export Android APK"
        panel.allowedContentTypes = [UTType(filenameExtension: Self.androidPackageExtension) ?? .data]
        panel.nameFieldStringValue = "\(wrap.appFileName).\(Self.androidPackageExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        // Snapshot AppKit artwork and store state before work leaves the main actor.
        guard let iconPNG = IcnsWriter.pngData(from: exporter.resolvedIcon(for: wrap),
                                              pixels: Self.androidIconPixels) else {
            showAndroidExportError(IcnsWriter.WriteError.renderFailed(Self.androidIconPixels))
            return
        }
        let configuration = store.configuration(for: wrap)
        let sdkDirectory = preferences.androidSDKDirectory
        let javaHome = preferences.androidJavaHome
        let signingDirectory = AppSupport.androidSigningDirectory
        isBuilding = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBuilding = false }

            do {
                // Android tools can take minutes; the library remains responsive.
                let output = try await Task.detached(priority: .userInitiated) {
                    try AndroidAPKExporter.build(configuration: configuration,
                                                 iconPNG: iconPNG,
                                                 destination: destination,
                                                 sdkDirectory: sdkDirectory,
                                                 javaHome: javaHome,
                                                 signingDirectory: signingDirectory)
                }.value
                self.sheet = nil
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch {
                self.showAndroidExportError(error)
            }
        }
    }

    @MainActor
    func revealAndroidBackupFolder() {
        do {
            try AppSupport.createDirectory(AppSupport.directory)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppSupport.directory.path)
        } catch {
            showAndroidExportError(error)
        }
    }

    @MainActor
    private func showAndroidExportError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't export the Android app"
        alert.informativeText = Self.describe(error)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
