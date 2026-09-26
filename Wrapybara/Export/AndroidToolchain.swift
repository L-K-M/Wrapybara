import Foundation

/// Resolves the optional SDK and JDK without downloading or changing either.
struct AndroidToolchain {
    static let targetSDK = 35
    static let buildToolsVersion = "35.0.0"
    static let minimumJavaVersion = 17
    static let minimumSDK = 26

    enum Tool: String {
        case aapt2, zipalign, java, javac, keytool, jar
    }

    enum ToolchainError: LocalizedError {
        case missingFile(String)
        case missingJava
        case missingJavaTool(String)
        case unsupportedJava(String)
        case failed(String, String)

        var errorDescription: String? {
            switch self {
            case .missingFile(let path):
                return "Android export needs \(path). Install Android SDK Platform "
                    + "\(targetSDK) and Build-Tools \(buildToolsVersion)."
            case .missingJava:
                return "Android export needs JDK \(minimumJavaVersion) or later. "
                    + "Install a JDK, or choose its home folder in Export Android APK."
            case .missingJavaTool(let path):
                return "Android export needs \(path). Choose a complete JDK "
                    + "\(minimumJavaVersion) or later in Export Android APK."
            case .unsupportedJava(let version):
                return "Android export needs JDK \(minimumJavaVersion) or later; found \(version)."
            case .failed(let tool, let message):
                return "Android \(tool) failed: \(message)"
            }
        }
    }

    private let sdkDirectory: URL
    private let javaHome: URL

    var androidJar: URL {
        sdkDirectory.appendingPathComponent("platforms/android-\(Self.targetSDK)/android.jar")
    }

    var d8Jar: URL { buildToolsDirectory.appendingPathComponent("lib/d8.jar") }
    var apkSignerJar: URL { buildToolsDirectory.appendingPathComponent("lib/apksigner.jar") }
    var lambdaStubsJar: URL { buildToolsDirectory.appendingPathComponent("core-lambda-stubs.jar") }

    private var buildToolsDirectory: URL {
        sdkDirectory.appendingPathComponent("build-tools/\(Self.buildToolsVersion)")
    }

    static func discover(sdkDirectory: URL, javaHome: URL? = nil) throws -> AndroidToolchain {
        let resolvedJavaHome = try javaHome ?? findJavaHome()
        let toolchain = AndroidToolchain(sdkDirectory: sdkDirectory, javaHome: resolvedJavaHome)

        for file in [toolchain.androidJar, toolchain.d8Jar, toolchain.apkSignerJar,
                     toolchain.lambdaStubsJar] {
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw ToolchainError.missingFile(file.path)
            }
        }
        for tool in [Tool.aapt2, .zipalign] {
            guard FileManager.default.isExecutableFile(atPath: toolchain.executable(tool).path) else {
                throw ToolchainError.missingFile(toolchain.executable(tool).path)
            }
        }
        for tool in [Tool.java, .javac, .keytool, .jar] {
            guard FileManager.default.isExecutableFile(atPath: toolchain.executable(tool).path) else {
                throw ToolchainError.missingJavaTool(toolchain.executable(tool).path)
            }
        }

        let result = try toolchain.run(.javac, arguments: ["-version"])
        let version = (result.standardOutput + result.standardError)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let component = version.split(whereSeparator: \.isWhitespace).dropFirst().first
        guard let majorText = component?.split(separator: ".").first,
              let major = Int(majorText), major >= minimumJavaVersion else {
            throw ToolchainError.unsupportedJava(version)
        }
        return toolchain
    }

    @discardableResult
    func run(_ tool: Tool, arguments: [String]) throws -> ProcessRunner.Result {
        let result = try ProcessRunner.run(executable(tool).path, arguments: arguments)
        guard result.succeeded else { throw ToolchainError.failed(tool.rawValue, result.message) }
        return result
    }

    private func executable(_ tool: Tool) -> URL {
        switch tool {
        case .java, .javac, .keytool, .jar:
            return javaHome.appendingPathComponent("bin/\(tool.rawValue)")
        case .aapt2, .zipalign:
            return buildToolsDirectory.appendingPathComponent(tool.rawValue)
        }
    }

    private static func findJavaHome() throws -> URL {
        if let home = ProcessInfo.processInfo.environment["JAVA_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
        }

        let locator = "/usr/libexec/java_home"
        guard FileManager.default.isExecutableFile(atPath: locator),
              let result = try? ProcessRunner.run(locator, arguments: ["-v", "\(minimumJavaVersion)+"]),
              result.succeeded else { throw ToolchainError.missingJava }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw ToolchainError.missingJava }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
