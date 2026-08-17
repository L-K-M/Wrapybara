import WebKit

/// Turns the boosts that match a URL into the user scripts a web view runs.
///
/// The awkward shape of this problem is that `WKUserScript`s are attached to a
/// *configuration*, not to a navigation, while boosts are chosen per URL. So the
/// scripts are rebuilt on each navigation — in `decidePolicyFor`, before the load
/// starts, which is early enough for the `documentStart` stylesheet to land before
/// first paint. Same-document navigations (a single-page app changing its URL) never
/// reach that delegate at all, so those are handled by re-evaluating the stylesheet
/// directly; `BoostScripts.navigationReporter` is what notices them.
struct BoostInjector {

    var configuration: WrapConfiguration

    /// Whether the wrap wants the `Notification` shim.
    var forwardsNotifications: Bool { configuration.wrap.behavior.forwardsWebNotifications }

    // MARK: Stylesheet

    /// The combined stylesheet for the boosts that apply to `url`.
    func stylesheet(for url: URL) -> String {
        BoostCSSGenerator.stylesheet(for: configuration.boosts(matching: url))
    }

    /// A script that installs (or updates) the stylesheet for `url`.
    ///
    /// Always produced, even when the stylesheet is empty — an empty one is how a
    /// boost being switched *off* takes effect on a page that's already open.
    func stylesheetScript(for url: URL) -> String {
        BoostScripts.applyStylesheet(stylesheet(for: url))
    }

    // MARK: User scripts

    /// Everything to install for a load of `url`, in the order it should run.
    func userScripts(for url: URL) -> [WKUserScript] {
        var scripts: [WKUserScript] = []

        // 1. Selector builder: needed by the picker, and by the editor's preview.
        scripts.append(script(BoostScripts.selectorBuilder, at: .atDocumentStart))

        // 2. The stylesheet, before first paint so a dark boost doesn't flash white.
        scripts.append(script(stylesheetScript(for: url), at: .atDocumentStart))

        // 3. The notification shim, before the page's own scripts can capture the real
        //    `Notification` and hold a reference the shim can't replace.
        if forwardsNotifications {
            scripts.append(script(BoostScripts.notificationShim, at: .atDocumentStart))
        }

        // 4. Soft-navigation reporting, after the History API exists.
        scripts.append(script(BoostScripts.navigationReporter, at: .atDocumentEnd))

        // 5. The boosts' own JavaScript, in boost order, each at its chosen time.
        for boost in configuration.boosts(matching: url) where boost.hasRunnableJavaScript {
            scripts.append(script(wrapped(boost),
                                  at: boost.javaScriptInjectionTime == .documentStart
                                      ? .atDocumentStart : .atDocumentEnd))
        }

        return scripts
    }

    /// Wraps a boost's script so a syntax error or a thrown exception in one boost
    /// can't stop the boosts after it — and so its top-level `var`s and `function`s
    /// stay out of the page's global scope.
    ///
    /// The name is included in the console message because "a boost threw" is useless
    /// when six are enabled.
    func wrapped(_ boost: Boost) -> String {
        let name = BoostScripts.jsStringLiteral(boost.name)
        return """
        (function () {
          try {
        \(boost.javaScript)
          } catch (error) {
            console.error("Wrapybara boost " + \(name) + " failed:", error);
          }
        })();
        """
    }

    private func script(_ source: String, at time: WKUserScriptInjectionTime) -> WKUserScript {
        // `forMainFrameOnly: true` throughout. A boost is a page customization, and
        // running it in every ad iframe would be both wasteful and, for a boost with
        // JavaScript, a genuine expansion of what the user thought they enabled.
        WKUserScript(source: source, injectionTime: time, forMainFrameOnly: true)
    }

    // MARK: Diagnostics

    /// A short description of what will be applied to `url`, for the editor's status
    /// line and for the Boosts menu.
    func summary(for url: URL) -> String {
        let matching = configuration.boosts(matching: url)
        guard !matching.isEmpty else { return "No boosts on this page" }
        let names = matching.map(\.name).joined(separator: ", ")
        return matching.count == 1 ? "1 boost: \(names)" : "\(matching.count) boosts: \(names)"
    }
}
