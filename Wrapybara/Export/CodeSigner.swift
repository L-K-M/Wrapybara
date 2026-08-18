import Foundation

/// Signs a generated app bundle.
///
/// **This step is not optional.** A bundle's code signature seals its `Info.plist`,
/// and the exporter writes a brand-new one — so the copied runtime binary's inherited
/// signature no longer matches its bundle. On Apple Silicon the kernel refuses to
/// execute an arm64 binary whose signature doesn't validate, so an unsigned or
/// stale-signed wrap wouldn't launch at all.
///
/// Signing needs `/usr/bin/codesign`, which is a Command Line Tools shim rather than
/// part of the base system, so its absence is a first-class, explainable failure
/// rather than a mysterious one.
enum CodeSigner {

    static let codesignPath = "/usr/bin/codesign"
    static let securityPath = "/usr/bin/security"
    static let xcodeSelectPath = "/usr/bin/xcode-select"

    /// Ad-hoc: no certificate, no keychain, no Apple Developer account. Enough to
    /// launch, not enough to avoid Gatekeeper's first-run prompt.
    static let adHocIdentity = "-"

    enum SigningError: LocalizedError {
        case toolsMissing
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .toolsMissing:
                return "The Xcode Command Line Tools aren't installed, so Wrapybara can't "
                    + "sign the app it just built — and macOS won't run an unsigned app on "
                    + "Apple Silicon."
            case .failed(let message):
                return "Signing failed: \(message)"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .toolsMissing:
                return "Run “xcode-select --install” in Terminal, then build the wrap again."
            case .failed:
                return nil
            }
        }
    }

    /// Whether signing can work at all right now.
    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: codesignPath)
            && (try? ProcessRunner.run(xcodeSelectPath, arguments: ["-p"], timeout: 10))?.succeeded == true
    }

    /// Signs the bundle at `url`.
    ///
    /// - Parameters:
    ///   - identity: a Developer ID common name, or `adHocIdentity` for ad-hoc.
    ///   - entitlements: an optional entitlements plist to seal in. Generated apps
    ///     don't use one — see `Wrapybara.entitlements` for why.
    static func sign(bundleAt url: URL,
                     identity: String = adHocIdentity,
                     entitlements: URL? = nil) throws {
        guard FileManager.default.isExecutableFile(atPath: codesignPath) else {
            throw SigningError.toolsMissing
        }

        var arguments = [
            "--force",
            // Sign nested code first, then the outer bundle. The runtime copy in
            // Contents/MacOS is the only nested Mach-O, but --deep costs nothing and
            // keeps this correct if a future wrap embeds a helper.
            "--deep",
            "--sign", identity,
        ]
        if identity == adHocIdentity {
            // Timestamps need the network and a real identity; an ad-hoc signature
            // can't carry one, and a wrap built on a plane should still build.
            arguments.append("--timestamp=none")
        } else {
            // A Developer ID signature keeps a secure timestamp — explicit rather
            // than relying on the toolchain default, per Apple's notarization
            // guidance. This is the step that touches the network.
            arguments.append("--timestamp")
        }
        if let entitlements {
            arguments.append(contentsOf: ["--entitlements", entitlements.path])
        }
        arguments.append(url.path)

        let result = try ProcessRunner.run(codesignPath, arguments: arguments)
        guard result.succeeded else { throw SigningError.failed(result.message) }
    }

    /// Verifies that the bundle at `url` has a signature the kernel will accept.
    ///
    /// Called right after signing: a `codesign` that exits 0 but leaves an invalid
    /// seal (a stale resource left in the bundle, say) would otherwise only show up
    /// as an app that dies silently on launch.
    static func verify(bundleAt url: URL) throws {
        let result = try ProcessRunner.run(
            codesignPath, arguments: ["--verify", "--deep", "--strict", url.path])
        guard result.succeeded else { throw SigningError.failed(result.message) }
    }

    /// The Developer ID Application identities in the user's keychains, as
    /// `(hash, name)` pairs, so Settings can offer real signing to whoever has it.
    ///
    /// Parses `security find-identity -v -p codesigning`, whose lines look like:
    /// `  1) A1B2C3… "Developer ID Application: Someone (TEAMID)"`
    static func availableSigningIdentities() -> [(hash: String, name: String)] {
        guard let result = try? ProcessRunner.run(
            securityPath, arguments: ["find-identity", "-v", "-p", "codesigning"], timeout: 20),
              result.succeeded else { return [] }
        return parseIdentities(result.standardOutput)
    }

    /// Pure half of `availableSigningIdentities`, so the parsing is unit-testable
    /// without a keychain.
    static func parseIdentities(_ output: String) -> [(hash: String, name: String)] {
        var identities: [(hash: String, name: String)] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Require the `N)` index prefix so the trailing "N valid identities
            // found" summary line is skipped.
            guard let parenthesis = trimmed.firstIndex(of: ")"),
                  trimmed[trimmed.startIndex..<parenthesis].allSatisfy(\.isNumber),
                  let firstQuote = trimmed.firstIndex(of: "\""),
                  let lastQuote = trimmed.lastIndex(of: "\""),
                  firstQuote < lastQuote else { continue }

            let afterParen = trimmed.index(after: parenthesis)
            let hash = trimmed[afterParen..<firstQuote].trimmingCharacters(in: .whitespaces)
            let name = String(trimmed[trimmed.index(after: firstQuote)..<lastQuote])
            guard !hash.isEmpty, !name.isEmpty else { continue }
            identities.append((hash: hash, name: name))
        }
        return identities
    }
}
