import Foundation

/// Pure classification of installed and release version strings for update checks.
enum UpdateVersionComparison: Equatable {
    case updateAvailable(remote: SemanticVersion, current: SemanticVersion)
    case upToDate
    case invalidCurrent(String)
    case invalidRemote(String)

    static func evaluate(remote remoteValue: String, current currentValue: String) -> Self {
        guard let current = SemanticVersion(currentValue) else {
            return .invalidCurrent(currentValue)
        }
        guard let remote = SemanticVersion(remoteValue) else {
            return .invalidRemote(remoteValue)
        }
        return remote > current ? .updateAvailable(remote: remote, current: current) : .upToDate
    }
}
