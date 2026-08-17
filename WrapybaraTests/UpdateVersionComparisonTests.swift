import XCTest
@testable import Wrapybara

final class UpdateVersionComparisonTests: XCTestCase {

    func testReportsUpdateWhenRemoteIsNewer() {
        guard case let .updateAvailable(remote, current) = UpdateVersionComparison.evaluate(
            remote: "v2.0.0", current: "1.9.0") else {
            return XCTFail("Expected update")
        }
        XCTAssertEqual(remote, SemanticVersion("v2.0.0"))
        XCTAssertEqual(current, SemanticVersion("1.9.0"))
    }

    func testReportsUpToDateForEqualOrOlderRelease() {
        XCTAssertEqual(UpdateVersionComparison.evaluate(remote: "1.2.0", current: "1.2"),
                       .upToDate)
        XCTAssertEqual(UpdateVersionComparison.evaluate(remote: "1.1.9", current: "1.2.0"),
                       .upToDate)
    }

    func testIdentifiesInvalidInstalledVersion() {
        XCTAssertEqual(UpdateVersionComparison.evaluate(remote: "2.0.0", current: "broken"),
                       .invalidCurrent("broken"))
    }

    func testIdentifiesInvalidReleaseTag() {
        XCTAssertEqual(UpdateVersionComparison.evaluate(remote: "latest", current: "1.0.0"),
                       .invalidRemote("latest"))
    }

    func testInstalledVersionFailureTakesPriorityWhenBothAreInvalid() {
        XCTAssertEqual(UpdateVersionComparison.evaluate(remote: "latest", current: "broken"),
                       .invalidCurrent("broken"))
    }
}
