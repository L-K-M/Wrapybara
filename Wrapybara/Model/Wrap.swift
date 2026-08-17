import Foundation

/// One site turned into an app: the thing Wrapybara's library lists and its
/// exporter writes to disk as a `.app`.
struct Wrap: Codable, Identifiable, Equatable {

    var id: UUID
    /// The app's name, and therefore the `.app` file name and menu-bar title.
    var name: String
    /// Where the app opens, and the origin that defines "inside" this wrap.
    var homeURL: URL
    /// The generated app's `CFBundleIdentifier`. Fixed at creation and never
    /// changed afterwards: it keys the app's cookie store, its `UserDefaults`
    /// domain and its Launch Services registration, so editing it would silently
    /// log the user out of their own app.
    var bundleIdentifier: String
    var behavior: WrapBehavior
    /// Boosts authored for this wrap alone.
    var boosts: [Boost]
    /// Shared boosts (from `WrapLibrary.sharedBoosts`) this wrap opts into.
    var enabledSharedBoostIDs: [UUID]
    var icon: WrapIcon
    var createdAt: Date
    var updatedAt: Date
    /// Absolute path of the generated `.app`, once it has been built. `nil` means
    /// the wrap exists only in the library.
    var installedAppPath: String?
    /// The Wrapybara version whose runtime is baked into the installed app, so the
    /// library can offer to refresh a wrap built by an older build.
    var installedRuntimeVersion: String?

    init(id: UUID = UUID(),
         name: String = "",
         homeURL: URL = Wrap.blankURL,
         bundleIdentifier: String = "",
         behavior: WrapBehavior = .default,
         boosts: [Boost] = [],
         enabledSharedBoostIDs: [UUID] = [],
         icon: WrapIcon = WrapIcon(),
         createdAt: Date = Date(),
         updatedAt: Date = Date(),
         installedAppPath: String? = nil,
         installedRuntimeVersion: String? = nil) {
        self.id = id
        self.name = name
        self.homeURL = homeURL
        self.bundleIdentifier = bundleIdentifier
        self.behavior = behavior
        self.boosts = boosts
        self.enabledSharedBoostIDs = enabledSharedBoostIDs
        self.icon = icon
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.installedAppPath = installedAppPath
        self.installedRuntimeVersion = installedRuntimeVersion
    }

    /// The URL a wrap falls back to when its stored `homeURL` is missing or
    /// unreadable. `about:blank` is a valid absolute URL so this can't fail; the
    /// `??` is only there to keep a force-unwrap out of the codebase.
    static let blankURL = URL(string: "about:blank") ?? URL(fileURLWithPath: "/")

    // MARK: Derived

    /// The `.app` file name (without extension) — the name with anything that
    /// can't be in a path folded out. See `AppNameSanitizer`.
    var appFileName: String { AppNameSanitizer.fileName(for: name) }

    /// The host that defines this wrap, lowercased, e.g. `mail.proton.me`.
    var homeHost: String { homeURL.host?.lowercased() ?? "" }

    /// Every host treated as inside the wrap: the home host plus the extras.
    var inAppHosts: [String] {
        var hosts = [homeHost]
        hosts.append(contentsOf: behavior.additionalInAppHosts
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        return hosts.filter { !$0.isEmpty }
    }

    /// Where the built app currently is on disk, if it's there.
    var installedAppURL: URL? {
        guard let path = installedAppPath, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// True when the installed app was built by a different Wrapybara version than
    /// the one running — the runtime inside it is stale, and features added since
    /// won't be there until it's rebuilt.
    func hasStaleRuntime(currentVersion: String) -> Bool {
        guard installedAppPath != nil else { return false }
        guard let installed = installedRuntimeVersion else { return true }
        return installed != currentVersion
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, name, homeURL, bundleIdentifier, behavior, boosts
        case enabledSharedBoostIDs, icon, createdAt, updatedAt
        case installedAppPath, installedRuntimeVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.value(.id, or: UUID())
        self.name = c.value(.name, or: "")
        self.homeURL = c.value(.homeURL, or: Wrap.blankURL)
        self.bundleIdentifier = c.value(.bundleIdentifier, or: "")
        self.behavior = c.value(.behavior, or: WrapBehavior.default)
        self.boosts = c.value(.boosts, or: [Boost]())
        self.enabledSharedBoostIDs = c.value(.enabledSharedBoostIDs, or: [UUID]())
        self.icon = c.value(.icon, or: WrapIcon())
        self.createdAt = c.value(.createdAt, or: Date())
        self.updatedAt = c.value(.updatedAt, or: Date())
        self.installedAppPath = c.optional(.installedAppPath)
        self.installedRuntimeVersion = c.optional(.installedRuntimeVersion)
    }
}
