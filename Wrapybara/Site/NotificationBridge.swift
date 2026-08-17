import AppKit
import UserNotifications

/// Turns a page's `Notification` calls into real macOS notifications.
///
/// `WKWebView` implements no part of the Notifications API — a web app that posts
/// notifications is simply mute inside a wrapper, which for a chat or mail app is the
/// difference between usable and not. `BoostScripts.notificationShim` replaces the
/// page's `Notification` with one that posts here.
///
/// Off unless the wrap asks for it (`WrapBehavior.forwardsWebNotifications`). Two
/// reasons: replacing a page global is intrusive, and a site that currently
/// feature-detects `Notification` and stays quiet will start asking once it finds one.
final class NotificationBridge: NSObject {

    /// A notification the page asked for. Every field is re-validated here — this
    /// arrives from page JavaScript, which may be the site's or a boost's.
    struct Payload: Equatable {
        var id: Int
        var title: String
        var body: String
        var tag: String
        var isSilent: Bool

        /// Longest text forwarded. Notification Center truncates anyway, and a
        /// megabyte of "title" from a runaway script shouldn't be copied around.
        static let maximumTextLength = 500

        init?(_ raw: Any?) {
            guard let dictionary = raw as? [String: Any] else { return nil }
            // A missing id is fine — it only exists so a click can be routed back —
            // but a non-numeric one means the payload isn't from our shim.
            let id = (dictionary["id"] as? NSNumber)?.intValue ?? 0
            let title = Self.clean(dictionary["title"])
            let body = Self.clean(dictionary["body"])
            // A notification with neither title nor body would post an empty banner.
            guard !title.isEmpty || !body.isEmpty else { return nil }
            self.id = id
            self.title = title
            self.body = body
            self.tag = Self.clean(dictionary["tag"])
            self.isSilent = (dictionary["silent"] as? NSNumber)?.boolValue ?? false
        }

        private static func clean(_ raw: Any?) -> String {
            guard let text = raw as? String else { return "" }
            let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return String(collapsed.prefix(maximumTextLength))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Called when the user clicks a forwarded notification, with the page-side id, so
    /// the shim's `onclick` can fire and the web app can open the right conversation.
    var onActivate: ((Int) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private var isAuthorized = false
    private var hasRequestedAuthorization = false
    /// The app name, used as the notification's title when the page gives only a body.
    private let appName: String

    init(appName: String) {
        self.appName = appName
        super.init()
        center.delegate = self
    }

    /// Asks for permission, once, the first time a page actually wants to notify.
    ///
    /// Deliberately lazy rather than at launch: a permission prompt the user sees
    /// before the app has done anything is the kind of thing that gets an app deleted.
    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            if let error {
                NSLog("Wrapybara: notification authorization failed: \(error.localizedDescription)")
            }
            DispatchQueue.main.async { self?.isAuthorized = granted }
        }
    }

    /// Posts `payload` as a system notification.
    func post(_ payload: Payload) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = payload.title.isEmpty ? appName : payload.title
        content.body = payload.body
        if !payload.isSilent { content.sound = .default }
        // Carry the page-side id through so `didReceive response` can route the click
        // back into the page.
        content.userInfo = [Self.pageIdentifierKey: payload.id]

        // A `tag` in the web API means "replace the notification with this tag".
        // `UNNotificationRequest`'s identifier has exactly that behaviour, so the tag
        // maps straight onto it; without one, each notification is its own.
        let identifier = payload.tag.isEmpty ? UUID().uuidString : "tag:\(payload.tag)"
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                NSLog("Wrapybara: couldn't post notification: \(error.localizedDescription)")
            }
        }
    }

    static let pageIdentifierKey = "WBPageNotificationID"
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationBridge: UNUserNotificationCenterDelegate {

    /// Show the banner even when the app is frontmost. A web app posting a
    /// notification about a message in another channel is still worth seeing, and this
    /// is what the same site does in a browser tab.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo[Self.pageIdentifierKey] as? Int) ?? 0
        onActivate?(id)
        completionHandler()
    }
}
