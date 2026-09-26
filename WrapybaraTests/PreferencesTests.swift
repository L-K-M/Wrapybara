import XCTest
@testable import Wrapybara

final class PreferencesTests: XCTestCase {
    func testClearedAndroidSDKFieldFallsBackToTheStandardLocation() throws {
        let suite = "WrapybaraTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let standard = preferences.androidSDKDirectory.standardizedFileURL.path

        preferences.androidSDKDirectoryPath = " \n"
        XCTAssertEqual(preferences.androidSDKDirectory.standardizedFileURL.path, standard)
    }
}
