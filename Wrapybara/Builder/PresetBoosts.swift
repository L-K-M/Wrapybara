import Foundation

/// Ready-made boosts for the shared shelf.
///
/// A preset is just a `Boost` value — the same thing an import produces, minus the
/// file. They land on the shared shelf switched on for no wrap (the per-wrap
/// checkbox is the opt-in), and they carry no JavaScript, so none of them trips the
/// imported-script trust gate. Each one's heuristic trade-off is written in its
/// notes, the house style for the aggressive options.
///
/// Builder-side on purpose: nothing here ships inside a generated app until a user
/// adds one to a wrap.
enum PresetBoosts {

    /// Dark, Readable, Kill Sticky Headers, Monospace Everything, No Cookie Banners.
    static let all: [Boost] = [dark, readable, killStickyHeaders, monospaceEverything, noCookieBanners]

    /// A blanket dark theme, using the aggressive colour reach — with the warning
    /// in the notes, exactly where the editor's own copy puts it.
    static let dark = Boost(
        name: "Dark",
        match: .everywhere,
        theme: BoostTheme(
            backgroundColor: "#161617",
            textColor: "#E8E6E3",
            linkColor: "#8AB4F8",
            colorReach: .everything),
        notes: "Blanket dark theme. The reach is “Every element”, which will occasionally "
            + "flatten a design that used background colour to convey structure — switch "
            + "“Apply background to” back to “Page background only” for a gentler version.")

    /// Long-form reading: serif stack, a touch larger, a touch airier, in a column.
    static let readable = Boost(
        name: "Readable",
        match: .everywhere,
        theme: BoostTheme(
            fontFamily: #""Iowan Old Style", Georgia, serif"#,
            fontScale: 1.08,
            lineHeightScale: 1.15,
            readableWidth: 680),
        notes: "Serif body text at 108% with a 680 pt reading column. Icon fonts are left "
            + "alone, so icons don't turn into tofu. The width cap only reaches "
            + "article/main elements — an app with an unusual layout may need the "
            + "readable-width knob switched off.")

    /// Sticky and fixed chrome, pinned back into the page's flow.
    static let killStickyHeaders = Boost(
        name: "Kill Sticky Headers",
        match: .everywhere,
        css: """
        /* Sticky and fixed chrome follows you down the page. Re-pinning it as
           absolute (rather than hiding it) scrolls it away with the page while
           leaving the header itself at the top where it belongs. */
        header, nav, [role="banner"], [role="navigation"],
        [class*="sticky"], [class*="Sticky"],
        [class*="fixed-header"], [class*="FixedHeader"] {
          position: absolute !important;
        }
        """,
        notes: "Heuristic: it matches common header containers and class names, so a "
            + "site with unusual markup may keep its sticky header — or lose the "
            + "positioning of something that isn't one. Adjust the selector list in "
            + "the Code pane for the site you're wrapping.")

    /// Every proportional font swapped for the system monospace. Icon fonts are
    /// excluded by the generator, so icons survive.
    static let monospaceEverything = Boost(
        name: "Monospace Everything",
        match: .everywhere,
        theme: BoostTheme(
            fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace"),
        notes: "All body text in the system monospace, code included. Icon fonts are "
            + "left alone. Surprisingly pleasant for dashboards and docs; ruinous "
            + "for anything designed.")

    /// The well-known consent SDK containers, hidden. CSS-only, so it can only hide
    /// banners it recognises — it never answers one.
    static let noCookieBanners = Boost(
        name: "No Cookie Banners",
        match: .everywhere,
        css: """
        /* The common consent SDK containers. Deliberately narrow: hiding a banner
           never *answers* it, and a selector broad enough to catch every banner is
           broad enough to hide the wrong thing. A banner that uses none of these
           stays put rather than risking a false hide. */
        #onetrust-consent-sdk, #onetrust-banner-sdk,
        #CybotCookiebotDialog, #CybotCookiebotDialogBodyUnderlay,
        .cc-window, .cc-banner,
        #cookie-law-info-bar, #cookie-law-info-again,
        #hs-eu-cookie-confirmation, .evidon-banner,
        [aria-label="cookieconsent"] {
          display: none !important;
        }
        """,
        notes: "Hides the well-known consent SDKs (OneTrust, Cookiebot, Cookie Consent, "
            + "cookie-law-info, HubSpot, Evidon). Hiding is not answering: a site that "
            + "gates content behind a real choice will still gate it.")
}
