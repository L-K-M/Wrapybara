import XCTest
@testable import Wrapybara

final class NavigationPolicyTests: XCTestCase {

    private let hosts = ["app.example.com", "accounts.example.net"]

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("bad test URL \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    private func decide(_ string: String,
                        policy: WrapBehavior.ExternalLinkPolicy = .openInDefaultBrowser,
                        userInitiated: Bool = true,
                        newWindow: Bool = false) -> NavigationPolicy.Decision {
        NavigationPolicy.decide(for: url(string), inAppHosts: hosts, policy: policy,
                                isUserInitiated: userInitiated, targetsNewWindow: newWindow)
    }

    // MARK: Inside the wrap

    func testInAppHostIsAllowed() {
        XCTAssertEqual(decide("https://app.example.com/inbox"), .allow)
    }

    func testSubdomainOfInAppHostIsAllowed() {
        XCTAssertEqual(decide("https://eu.app.example.com/inbox"), .allow)
    }

    func testAdditionalHostIsInApp() {
        // The classic failure: an SSO hop on a different registrable domain gets bounced to
        // the browser, and the user can never sign in.
        XCTAssertEqual(decide("https://accounts.example.net/oauth"), .allow)
    }

    func testInAppTargetBlankBecomesATab() {
        XCTAssertEqual(decide("https://app.example.com/x", newWindow: true), .openInNewTab)
    }

    // MARK: Outside the wrap

    func testExternalLinkGoesToTheBrowserByDefault() {
        XCTAssertEqual(decide("https://news.example.org/story"), .openExternally)
    }

    func testKeepInAppPolicy() {
        XCTAssertEqual(decide("https://news.example.org/story", policy: .keepInApp), .allow)
    }

    func testOpenInNewTabPolicy() {
        XCTAssertEqual(decide("https://news.example.org/story", policy: .openInNewTab),
                       .openInNewTab)
    }

    // MARK: Redirects

    func testNonUserInitiatedNavigationStaysInTheApp() {
        // A login flow that bounces through an identity provider arrives here as a
        // redirect. Sending it to Safari would break the handshake, and the user would be
        // signed in to the browser instead of the app.
        XCTAssertEqual(decide("https://idp.example.org/authorize", userInitiated: false), .allow)
    }

    // MARK: Other schemes

    func testMailtoAndFriendsAlwaysLeave() {
        for scheme in ["mailto:someone@example.com", "tel:+15551234", "zoommtg://zoom.us/join",
                       "slack://open", "msteams:/l/chat"] {
            XCTAssertEqual(decide(scheme), .openExternally, "\(scheme) should hand off")
        }
    }

    func testHandOffSchemeLeavesEvenWhenNotUserInitiated() {
        // A web view can't load these at all, so swallowing one just makes the link look
        // broken.
        XCTAssertEqual(decide("mailto:x@example.com", userInitiated: false), .openExternally)
    }

    func testFileURLsAreBlocked() {
        XCTAssertEqual(decide("file:///etc/passwd"), .block)
    }

    func testWebKitInternalSchemesAreAllowed() {
        for scheme in ["about:blank", "blob:https://app.example.com/1234", "data:text/html,hi"] {
            XCTAssertEqual(decide(scheme), .allow, "\(scheme) should load")
        }
    }

    func testKeepInAppDoesNotLetMailtoLoadInTheWebView() {
        XCTAssertEqual(decide("mailto:x@example.com", policy: .keepInApp), .openExternally)
    }

    // MARK: Host checks

    func testIsInAppRejectsLookalikeSuffix() {
        XCTAssertFalse(NavigationPolicy.isInApp(url: url("https://evilapp.example.com.attacker.tld/"),
                                                inAppHosts: hosts))
        XCTAssertFalse(NavigationPolicy.isInApp(url: url("https://notapp.example.com/"),
                                                inAppHosts: ["app.example.com"]))
    }

    func testIsInAppByHostString() {
        XCTAssertTrue(NavigationPolicy.isInApp(host: "APP.example.com", inAppHosts: hosts))
        XCTAssertFalse(NavigationPolicy.isInApp(host: "", inAppHosts: hosts))
    }

    func testEmptyHostListMatchesNothing() {
        XCTAssertFalse(NavigationPolicy.isInApp(url: url("https://example.com/"), inAppHosts: []))
        XCTAssertFalse(NavigationPolicy.isInApp(url: url("https://example.com/"),
                                                inAppHosts: ["", "  "]))
    }
}
