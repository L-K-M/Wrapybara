import Foundation

/// Compiles a staged Android project and returns only a verified, signed APK.
enum AndroidAPKBuilder {
    private static let javaLanguageVersion = "8"
    private static let dexCompilerClass = "com.android.tools.r8.D8"
    private static let apkAlignment = "4"
    private static let nativePageAlignmentKB = "16"

    enum BuildError: LocalizedError {
        case noSources
        case noBytecode

        var errorDescription: String? {
            switch self {
            case .noSources: return "The Android runtime sources are missing."
            case .noBytecode: return "The Android compiler produced no bytecode."
            }
        }
    }

    static func build(projectDirectory: URL, toolchain: AndroidToolchain,
                      signingDirectory: URL, packageIdentifier: String) throws -> URL {
        let manager = FileManager.default
        let buildDirectory = projectDirectory.appendingPathComponent("build", isDirectory: true)
        let classesDirectory = buildDirectory.appendingPathComponent("classes", isDirectory: true)
        let dexDirectory = buildDirectory.appendingPathComponent("dex", isDirectory: true)
        for directory in [classesDirectory, dexDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let resources = buildDirectory.appendingPathComponent("resources.zip")
        let unsignedAPK = buildDirectory.appendingPathComponent("unsigned.apk")
        let alignedAPK = buildDirectory.appendingPathComponent("aligned.apk")
        let signedAPK = projectDirectory.appendingPathComponent("signed.apk")

        try toolchain.run(.aapt2, arguments: [
            "compile", "--dir", projectDirectory.appendingPathComponent("res").path,
            "-o", resources.path
        ])
        try toolchain.run(.aapt2, arguments: [
            "link", "-o", unsignedAPK.path, "-I", toolchain.androidJar.path,
            "--manifest", projectDirectory.appendingPathComponent("AndroidManifest.xml").path,
            "-A", projectDirectory.appendingPathComponent("assets").path, resources.path
        ])

        let sources = try files(in: projectDirectory.appendingPathComponent("src"), extension: "java")
        guard !sources.isEmpty else { throw BuildError.noSources }
        // The SDK supplies lambda compiler stubs absent from android.jar; D8 desugars them.
        try toolchain.run(.javac, arguments: [
            "-encoding", "UTF-8", "-source", javaLanguageVersion, "-target", javaLanguageVersion,
            "-bootclasspath", "\(toolchain.androidJar.path):\(toolchain.lambdaStubsJar.path)",
            "-d", classesDirectory.path
        ] + sources.map(\.path))
        let classes = try files(in: classesDirectory, extension: "class")
        guard !classes.isEmpty else { throw BuildError.noBytecode }

        // Invoke SDK jars with the selected JDK, independent of the user's shell PATH.
        try toolchain.run(.java, arguments: [
            "-cp", toolchain.d8Jar.path, dexCompilerClass, "--release",
            "--min-api", String(AndroidToolchain.minimumSDK),
            "--lib", toolchain.androidJar.path, "--output", dexDirectory.path
        ] + classes.map(\.path))
        let dexFiles = try files(in: dexDirectory, extension: "dex")
        guard !dexFiles.isEmpty else { throw BuildError.noBytecode }
        let archiveInputs = dexFiles.flatMap { ["-C", dexDirectory.path, $0.lastPathComponent] }
        try toolchain.run(.jar, arguments: [
            "--update", "--no-manifest", "--file", unsignedAPK.path
        ] + archiveInputs)
        try toolchain.run(.zipalign, arguments: [
            "-f", "-P", nativePageAlignmentKB, apkAlignment, unsignedAPK.path, alignedAPK.path
        ])

        let identity = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                              packageIdentifier: packageIdentifier,
                                                              toolchain: toolchain)
        try toolchain.run(.java, arguments: [
            "-jar", toolchain.apkSignerJar.path, "sign"
        ] + identity.signingArguments + ["--out", signedAPK.path, alignedAPK.path])
        try toolchain.run(.java, arguments: [
            "-jar", toolchain.apkSignerJar.path, "verify", "--verbose", signedAPK.path
        ])
        return signedAPK
    }

    private static func files(in directory: URL, extension suffix: String) throws -> [URL] {
        let manager = FileManager.default
        // Read each directory explicitly so unreadable sources cannot disappear silently.
        let children = try manager.contentsOfDirectory(at: directory,
                                                      includingPropertiesForKeys: [.isDirectoryKey])
        var result: [URL] = []
        for child in children {
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result.append(contentsOf: try files(in: child, extension: suffix))
                continue
            }
            if child.pathExtension == suffix { result.append(child) }
        }
        return result.sorted { $0.path < $1.path }
    }
}
