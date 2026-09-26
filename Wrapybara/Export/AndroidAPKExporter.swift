import Foundation

/// Coordinates a standalone Android build without changing the installed Mac app.
enum AndroidAPKExporter {
    static var androidRequirements: String {
        "Install Android SDK Platform \(AndroidToolchain.targetSDK), Build-Tools "
            + "\(AndroidToolchain.buildToolsVersion) and JDK \(AndroidToolchain.minimumJavaVersion) "
            + "or later. Wrapybara uses your local tools."
    }

    private static let buildLock = NSLock()
    private static let runtimeSources = ["AndroidSiteActivity", "AndroidNavigationPolicy"]
    private static let recordsFolder = "AndroidExports"

    enum ExportError: LocalizedError {
        case missingRuntime(String)
        case missingSigningKey
        case invalidRecord
        case emptyIcon

        var errorDescription: String? {
            switch self {
            case .missingRuntime(let name):
                return "Wrapybara's Android runtime is missing (\(name)). Reinstall Wrapybara."
            case .missingSigningKey:
                return "This app was exported before, but its Android signing key is missing. Restore Wrapybara's support folder from backup to update it."
            case .invalidRecord:
                return "This app's Android export record is missing or unreadable. Restore Wrapybara's support folder from backup."
            case .emptyIcon:
                return "The Android app icon could not be rendered."
            }
        }
    }

    private struct ExportRecord: Codable {
        enum State: String, Codable { case reserved, published }

        let versionCode: Int
        let state: State

        init(versionCode: Int, state: State) {
            self.versionCode = versionCode
            self.state = state
        }

        private enum CodingKeys: String, CodingKey { case versionCode, state }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            versionCode = values.value(.versionCode, or: 0)
            // Older records were written only after signing; never replace their missing key.
            state = values.value(.state, or: .published)
        }
    }

    static func build(configuration: WrapConfiguration, iconPNG: Data, destination: URL,
                      sdkDirectory: URL, javaHome: URL?, signingDirectory: URL,
                      passwords: AndroidSigningPasswordStore) throws -> URL {
        // Serialize key creation and version reservations across library windows.
        buildLock.lock()
        defer { buildLock.unlock() }

        guard !iconPNG.isEmpty else { throw ExportError.emptyIcon }
        let package = AndroidExportPlan.packageIdentifier(for: configuration.wrap.id)
        let records = signingDirectory.deletingLastPathComponent()
            .appendingPathComponent(recordsFolder, isDirectory: true)
        let recordURL = records.appendingPathComponent(package).appendingPathExtension("json")
        let previous = try readRecord(at: recordURL)
        let hasIdentity = FileManager.default.fileExists(atPath: signingDirectory.appendingPathComponent(package).path)
        if previous == nil, hasIdentity {
            throw ExportError.invalidRecord
        }
        if previous?.state == .published, !hasIdentity {
            throw ExportError.missingSigningKey
        }
        let plan = try AndroidExportPlan(configuration: configuration,
                                         versionCode: (previous?.versionCode ?? 0) + 1)
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdkDirectory, javaHome: javaHome)
        let sources = try runtimeSources.map { name -> (String, URL) in
            guard let source = Bundle.main.url(forResource: name, withExtension: "java.txt") else {
                throw ExportError.missingRuntime(name)
            }
            return (name, source)
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wrapybara-Android-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }

        try writeProject(plan, iconPNG: iconPNG, sources: sources, to: staging)

        // Reserve before key creation so a failed first build can retry without resetting versions.
        // Once published, keep protecting the key even when a later build fails.
        try writeRecord(ExportRecord(versionCode: plan.versionCode, state: previous?.state ?? .reserved),
                        to: recordURL)
        let apk = try AndroidAPKBuilder.build(projectDirectory: staging, toolchain: toolchain,
                                               signingDirectory: signingDirectory,
                                               packageIdentifier: package,
                                               passwords: passwords)

        // Protect the verified key before publishing; a failed copy may safely skip a number.
        try writeRecord(ExportRecord(versionCode: plan.versionCode, state: .published), to: recordURL)
        try Data(contentsOf: apk).write(to: destination, options: [.atomic])
        return destination
    }

    private static func readRecord(at url: URL) throws -> ExportRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let record = try? JSONDecoder().decode(ExportRecord.self, from: Data(contentsOf: url)) else {
            throw ExportError.invalidRecord
        }
        guard (1...AndroidExportPlan.maximumVersionCode).contains(record.versionCode) else {
            throw ExportError.invalidRecord
        }
        return record
    }

    private static func writeRecord(_ record: ExportRecord, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url, options: [.atomic])
    }

    private static func writeProject(_ plan: AndroidExportPlan, iconPNG: Data,
                                     sources: [(String, URL)], to directory: URL) throws {
        for path in ["res/drawable", "res/values", "assets", "src/com/wrapybara/runtime"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        try plan.manifest.write(to: directory.appendingPathComponent("AndroidManifest.xml"),
                                atomically: true, encoding: .utf8)
        try plan.stringResources.write(to: directory.appendingPathComponent("res/values/strings.xml"),
                                       atomically: true, encoding: .utf8)
        try iconPNG.write(to: directory.appendingPathComponent("res/drawable/icon.png"))
        try plan.runtimeConfiguration().write(to: directory.appendingPathComponent("assets/wrap.json"))
        let scripts = try AndroidBoostScript.make(boosts: plan.configuration.boosts)
        try JSONEncoder().encode(scripts)
            .write(to: directory.appendingPathComponent("assets/boosts.json"))
        for (name, source) in sources {
            try FileManager.default.copyItem(at: source,
                to: directory.appendingPathComponent("src/com/wrapybara/runtime/\(name).java"))
        }
    }
}
