import SwiftUI

/// The Behaviour tab: everything in `WrapBehavior`.
///
/// Every control writes straight through to the store, which republishes the wrap's
/// configuration — so a running copy of the app picks up most of these immediately.
/// The ones that only apply on the next build (or the next launch) say so.
struct BehaviorEditorView: View {

    @ObservedObject var model: LibraryModel
    let wrap: Wrap

    private var behavior: WrapBehavior { wrap.behavior }

    var body: some View {
        Form {
            Section("Window") {
                Picker("Chrome", selection: binding(\.chrome)) {
                    ForEach(WrapBehavior.Chrome.allCases) { Text($0.displayName).tag($0) }
                }
                if behavior.chrome == .none {
                    Text("The page runs edge to edge and the traffic lights float over it. "
                         + "The top strip of the page stays reserved for dragging the "
                         + "window — clicks there don't reach the site.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show the address in the toolbar", isOn: binding(\.showsAddressBar))
                    .disabled(!behavior.chrome.showsToolbar)
                Toggle("Allow native tabs (⌘T)", isOn: binding(\.allowsNativeTabs))
                Toggle("Reopen where I left off", isOn: binding(\.restoresSession))
                HStack {
                    Text("Opens at")
                    Spacer()
                    Stepper(value: binding(\.initialWindowWidth), in: 480...4000, step: 40) {
                        Text("\(Int(behavior.initialWindowWidth)) pt wide")
                            .monospacedDigit()
                    }
                    Stepper(value: binding(\.initialWindowHeight), in: 360...3000, step: 40) {
                        Text("\(Int(behavior.initialWindowHeight)) pt tall")
                            .monospacedDigit()
                    }
                }
                zoomRow
            }

            Section("Links") {
                Picker("Links outside this site", selection: binding(\.externalLinks)) {
                    ForEach(WrapBehavior.ExternalLinkPolicy.allCases) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text("Redirects and script-driven navigation always stay in the app, so a login "
                     + "that bounces through an identity provider can't dump you into Safari "
                     + "mid-handshake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HostListEditor(hosts: binding(\.additionalInAppHosts))
            }

            Section("Identity") {
                Picker("User agent", selection: binding(\.userAgentMode)) {
                    ForEach(WrapBehavior.UserAgentMode.allCases) { Text($0.displayName).tag($0) }
                }
                if behavior.userAgentMode == .custom {
                    TextField("User-Agent", text: binding(\.customUserAgent))
                        .font(.system(.callout, design: .monospaced))
                }
                if behavior.userAgentMode == .safari {
                    Text(WrapBehavior.desktopSafariUserAgent)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("System") {
                Toggle("Dock badge from the page title", isOn: binding(\.showsBadgeFromTitle))
                Text("Reads a count out of titles like “(3) Inbox”, the way a browser tab does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Forward the site's notifications", isOn: binding(\.forwardsWebNotifications))
                Text("WebKit has no notification support, so this installs a shim that replaces "
                     + "the page's Notification object. Sites that currently stay quiet because "
                     + "they can't notify will start asking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Offer the current page to Handoff", isOn: binding(\.advertisesHandoff))
                Toggle("Keep running after the last window closes",
                       isOn: binding(\.staysRunningWithoutWindows))
                Toggle("Ask before quitting with several windows open",
                       isOn: binding(\.confirmsQuitWithOpenTabs))
            }

            Section("Developer") {
                Toggle("Allow the Web Inspector", isOn: binding(\.isWebInspectorEnabled))
                Text("Adds Inspect Element to the page's context menu and Show Web Inspector "
                     + "(⌥⌘I) to the app's View menu. A running app picks this up without "
                     + "a rebuild.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var zoomRow: some View {
        HStack {
            Text("Page zoom")
            Slider(value: binding(\.pageZoom), in: 0.5...2, step: 0.05)
            Text("\(Int((behavior.pageZoom * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 46, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    /// A binding that writes one `WrapBehavior` field back through the store.
    ///
    /// Written as a key-path helper rather than 18 hand-rolled bindings: each one would
    /// otherwise be five identical lines, and the repetition is exactly where a
    /// copy-paste bug (writing the wrong field) hides.
    private func binding<Value>(_ keyPath: WritableKeyPath<WrapBehavior, Value>) -> Binding<Value> {
        Binding(
            get: { wrap.behavior[keyPath: keyPath] },
            set: { newValue in
                var updated = wrap
                updated.behavior[keyPath: keyPath] = newValue
                model.update(updated)
            })
    }
}

// MARK: - Extra in-app hosts

/// Editor for the extra hosts that count as inside the wrap.
private struct HostListEditor: View {

    @Binding var hosts: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Also treat these hosts as inside the app")
                .font(.callout)

            ForEach(Array(hosts.enumerated()), id: \.offset) { index, host in
                HStack {
                    Text(host)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button {
                        hosts.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                TextField("accounts.example.com", text: $draft)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(BoostMatcher.normalizedHost(draft).isEmpty)
            }
            Text("Subdomains of each entry count too. Add the host your login redirects through "
                 + "if signing in bounces you out to the browser.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let host = BoostMatcher.normalizedHost(draft)
        guard !host.isEmpty, !hosts.contains(host) else { return }
        hosts.append(host)
        draft = ""
    }
}
