import AppKit
import SwiftUI

/// The Settings window a *generated app* shows for ⌘,.
///
/// Read-only on purpose. A wrap's behaviour and its boosts are owned by the library in
/// Wrapybara, and having two writers for one configuration file — a running site app
/// and the builder — would mean last-save-wins and lost edits. So this window says
/// what this app is doing and what is applied to the page, and sends you to Wrapybara
/// to change it.
///
/// It exists at all because ⌘, that beeps is worse than ⌘, that explains.
final class SiteSettingsWindowController: NSWindowController {

    init(configuration: WrapConfiguration) {
        let view = SiteSettingsView(configuration: configuration)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "\(configuration.wrap.name) Settings"
        window.setContentSize(NSSize(width: 460, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteSettingsWindowController is created in code, not from a nib")
    }
}

/// The contents of a site app's Settings window.
private struct SiteSettingsView: View {

    let configuration: WrapConfiguration

    private var wrap: Wrap { configuration.wrap }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Behaviour") {
                        row("Window", wrap.behavior.chrome.displayName)
                        row("Links outside this site", wrap.behavior.externalLinks.displayName)
                        row("Native tabs", wrap.behavior.allowsNativeTabs ? "On" : "Off")
                        row("Reopen where I left off", wrap.behavior.restoresSession ? "On" : "Off")
                        row("Dock badge from page title",
                            wrap.behavior.showsBadgeFromTitle ? "On" : "Off")
                        row("Forward web notifications",
                            wrap.behavior.forwardsWebNotifications ? "On" : "Off")
                        row("User agent", wrap.behavior.userAgentMode.displayName)
                    }

                    section("Boosts (\(configuration.boosts.count))") {
                        if configuration.boosts.isEmpty {
                            Text("No boosts. Add one in Wrapybara to restyle this site.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(configuration.boosts) { boost in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: boost.isEnabled
                                          ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(boost.isEnabled ? Color.green : Color.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(boost.name).font(.callout)
                                        Text("\(boost.match.summary) · \(boost.contentsSummary)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text("Built by \(configuration.generatedBy)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Edit in Wrapybara…") { SiteAppDelegate.openWrapybara() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(wrap.name).font(.headline)
                Text(wrap.homeURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
        }
        .padding(20)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.callout)
            Spacer(minLength: 12)
            Text(value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
