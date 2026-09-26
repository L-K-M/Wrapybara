import Foundation

/// Portable inputs for the Android packager, without filesystem or UI access.
struct AndroidExportPlan {
    let configuration: WrapConfiguration
    let versionCode: Int

    static let maximumVersionCode = 2_100_000_000

    enum PlanError: LocalizedError {
        case invalidName
        case invalidURL
        case invalidVersion

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Give this wrap a name before exporting."
            case .invalidURL: return "Android apps require an HTTP or HTTPS home address without embedded credentials."
            case .invalidVersion: return "This Android app has exhausted its update version numbers."
            }
        }
    }

    init(configuration: WrapConfiguration, versionCode: Int) throws {
        let wrap = configuration.wrap
        guard !wrap.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlanError.invalidName
        }
        guard ["http", "https"].contains(wrap.homeURL.scheme?.lowercased() ?? ""),
              let host = wrap.homeURL.host, !host.isEmpty,
              wrap.homeURL.user == nil, wrap.homeURL.password == nil else {
            throw PlanError.invalidURL
        }
        guard (1...Self.maximumVersionCode).contains(versionCode) else {
            throw PlanError.invalidVersion
        }
        self.configuration = configuration
        self.versionCode = versionCode
    }

    /// UUID identity survives renaming and does not alter the Mac bundle identifier.
    static func packageIdentifier(for id: UUID) -> String {
        "com.wrapybara.site.w" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    var packageIdentifier: String { Self.packageIdentifier(for: configuration.wrap.id) }

    var manifest: String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <manifest xmlns:android="http://schemas.android.com/apk/res/android"
            package="\(packageIdentifier)" android:versionCode="\(versionCode)"
            android:versionName="\(versionCode)">
            <uses-sdk android:minSdkVersion="\(AndroidToolchain.minimumSDK)"
                android:targetSdkVersion="\(AndroidToolchain.targetSDK)" />
            <uses-permission android:name="android.permission.INTERNET" />
            <application android:label="@string/app_name" android:icon="@drawable/icon"
                android:theme="@android:style/Theme.Material.Light.NoActionBar"
                android:allowBackup="false" android:usesCleartextTraffic="true"
                android:supportsRtl="true">
                <activity android:name="com.wrapybara.runtime.AndroidSiteActivity"
                    android:exported="true" android:windowSoftInputMode="adjustResize">
                    <intent-filter>
                        <action android:name="android.intent.action.MAIN" />
                        <category android:name="android.intent.category.LAUNCHER" />
                    </intent-filter>
                </activity>
            </application>
        </manifest>
        """
    }

    var stringResources: String {
        // AAPT has a second escaping layer after XML, including @/? references.
        let name = configuration.wrap.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<resources><string name=\"app_name\" formatted=\"false\">\"\(name)\"</string></resources>"
    }

    func runtimeConfiguration() throws -> Data {
        let wrap = configuration.wrap
        let values: [String: Any] = [
            "name": wrap.name,
            "homeURL": wrap.homeURL.absoluteString,
            "openExternalLinksInBrowser": wrap.behavior.externalLinks == .openInDefaultBrowser,
            "allowedDomains": wrap.inAppHosts.map(BoostMatcher.normalizedHost).filter { !$0.isEmpty },
            "restoreLastPage": wrap.behavior.restoresSession,
        ]
        return try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }
}
