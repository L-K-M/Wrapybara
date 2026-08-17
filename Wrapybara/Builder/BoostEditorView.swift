import AppKit
import SwiftUI

/// The boost editor: knobs on the left, a live preview of the real site on the right.
///
/// The preview is the point. Restyling a site from the outside is guesswork, and
/// guessing with a two-second feedback loop is what makes it feel like work. Every
/// change here re-applies to a real `WKWebView` showing the actual page.
struct BoostEditorView: View {

    @ObservedObject var model: LibraryModel
    let wrap: Wrap
    let boost: Boost

    private enum Pane: String, CaseIterable, Identifiable {
        case look = "Look"
        case zap = "Zap"
        case code = "Code"
        case scope = "Scope"

        var id: String { rawValue }
    }

    @State private var pane: Pane = .look
    @State private var isPreviewShown = true
    @State private var cssDraft = ""
    @State private var javaScriptDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            HSplitView {
                controls
                    .frame(minWidth: 340, idealWidth: 380)
                if isPreviewShown {
                    BoostPreviewView(model: model, wrap: wrap, boost: boost)
                        .frame(minWidth: 360)
                }
            }
        }
        .onAppear {
            cssDraft = boost.css
            javaScriptDraft = boost.javaScript
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: binding(\.isEnabled))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(boost.isEnabled ? "Switched on" : "Switched off")

            TextField("Boost name", text: binding(\.name))
                .textFieldStyle(.plain)
                .font(.headline)

            Spacer()

            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Button {
                isPreviewShown.toggle()
            } label: {
                Image(systemName: isPreviewShown ? "sidebar.right" : "sidebar.squares.right")
            }
            .buttonStyle(.borderless)
            .help(isPreviewShown ? "Hide the preview" : "Show the preview")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: Panes

    @ViewBuilder
    private var controls: some View {
        switch pane {
        case .look: lookPane
        case .zap: zapPane
        case .code: codePane
        case .scope: scopePane
        }
    }

    // MARK: Look

    private var lookPane: some View {
        Form {
            Section("Colours") {
                optionalColor("Background", keyPath: \.backgroundColor)
                optionalColor("Text", keyPath: \.textColor)
                optionalColor("Links", keyPath: \.linkColor)
                optionalColor("Accent", keyPath: \.accentColor)
                Picker("Apply background to", selection: themeBinding(\.colorReach)) {
                    ForEach(BoostTheme.ColorReach.allCases) { Text($0.displayName).tag($0) }
                }
                if boost.theme.colorReach == .everything {
                    Text("Clears every element's own background so the page colour shows "
                         + "through. Effective, and it will occasionally flatten a design that "
                         + "used background colour to convey structure.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Type") {
                TextField("Font stack", text: optionalStringBinding(\.fontFamily),
                          prompt: Text(#""Iowan Old Style", Georgia, serif"#))
                TextField("Monospace font", text: optionalStringBinding(\.monospaceFontFamily),
                          prompt: Text("ui-monospace, Menlo, monospace"))
                slider("Text size", themeBinding(\.fontScale), range: 0.6...2, percent: true)
                slider("Line height", themeBinding(\.lineHeightScale), range: 0.8...2.4, percent: false)
                Picker("Case", selection: themeBinding(\.textTransform)) {
                    ForEach(BoostTheme.TextTransform.allCases) { Text($0.displayName).tag($0) }
                }
                optionalNumber("Readable width", keyPath: \.readableWidth,
                               range: 320...1400, suffix: "pt")
            }

            Section("Image adjustments") {
                slider("Brightness", themeBinding(\.brightness), range: 0.2...2, percent: true)
                slider("Contrast", themeBinding(\.contrast), range: 0.2...2, percent: true)
                slider("Saturation", themeBinding(\.saturation), range: 0...2, percent: true)
                slider("Hue rotate", themeBinding(\.hueRotate), range: -180...180, percent: false,
                       suffix: "°")
                slider("Invert", themeBinding(\.invert), range: 0...1, percent: true)
                slider("Greyscale", themeBinding(\.grayscale), range: 0...1, percent: true)
                if boost.theme.invert > 0 {
                    Toggle("Keep photos looking right",
                           isOn: themeBinding(\.preservesMediaWhenInverted))
                    Text("Counter-inverts images and video, the way the system's Smart Invert "
                         + "does, so photographs don't come out as negatives.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Surfaces") {
                optionalNumber("Corner radius", keyPath: \.cornerRadius, range: 0...40, suffix: "pt")
                Toggle("Hide images", isOn: themeBinding(\.hidesImages))
            }

            Section {
                Button("Reset every knob") { resetTheme() }
                    .disabled(boost.theme.isNeutral)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Zap

    private var zapPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Zapped elements")
                    .font(.headline)
                Text("Click **Pick an Element** and choose something in the preview. ↑ widens the "
                     + "selection to its container, ↓ narrows it back, Esc cancels.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Pick an Element…") {
                    model.beginPickingElement(for: boost, in: wrap)
                }
                .disabled(!isPreviewShown)
                .help(isPreviewShown ? "Choose an element in the preview"
                      : "Show the preview first")
            }
            .padding(14)

            Divider()

            if boost.zapSelectors.isEmpty {
                Text("Nothing zapped yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(14)
                Spacer()
            } else {
                List {
                    ForEach(Array(boost.zapSelectors.enumerated()), id: \.offset) { index, selector in
                        HStack(alignment: .top) {
                            Text(selector)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            if !BoostCSSGenerator.isSafeSelector(selector) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .help("This selector can't be used — it contains a character "
                                          + "that would break out of the rule.")
                            }
                            Button {
                                removeSelector(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Code

    private var codePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("CSS")
                    .font(.headline)
                CodeEditor(text: $cssDraft)
                    .frame(minHeight: 120)
                    .onChange(of: cssDraft) { newValue in
                        var updated = boost
                        updated.css = newValue
                        model.updateBoost(updated, in: wrap)
                    }
                Text("Applied after everything the knobs generate, so it always wins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("JavaScript")
                        .font(.headline)
                    Spacer()
                    Picker("", selection: binding(\.javaScriptInjectionTime)) {
                        ForEach(Boost.InjectionTime.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                CodeEditor(text: $javaScriptDraft)
                    .frame(minHeight: 120)
                    .onChange(of: javaScriptDraft) { newValue in
                        var updated = boost
                        updated.javaScript = newValue
                        // Editing a script is authoring it, so it's trusted. Only an
                        // *imported* script starts untrusted — see `Boost`.
                        if !newValue.isEmpty { updated.isJavaScriptTrusted = true }
                        model.updateBoost(updated, in: wrap)
                    }
                if boost.hasUntrustedJavaScript {
                    untrustedScriptWarning
                }
                Text("Runs in the page, with access to whatever this app is signed into.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
        }
    }

    private var untrustedScriptWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("This script came from an imported boost and hasn't run yet.")
                    .font(.callout)
                Text("Read it before you trust it. It will run inside your session on this site.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Trust and Run This Script") {
                    var updated = boost
                    updated.isJavaScriptTrusted = true
                    model.updateBoost(updated, in: wrap)
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Scope

    private var scopePane: some View {
        Form {
            Section("Where this boost applies") {
                Picker("Match", selection: matchBinding(\.kind)) {
                    ForEach(BoostMatch.Kind.allCases) { Text($0.displayName).tag($0) }
                }
                if boost.match.kind.usesPattern {
                    TextField("Pattern", text: matchBinding(\.pattern),
                              prompt: Text(patternPrompt))
                        .font(.system(.callout, design: .monospaced))
                }
                if boost.match.kind == .domain {
                    Toggle("Include subdomains", isOn: matchBinding(\.includesSubdomains))
                }
                if boost.match.kind == .glob || boost.match.kind == .regex {
                    Toggle("Case sensitive", isOn: matchBinding(\.isCaseSensitive))
                }
            }

            Section("Does it match the home page?") {
                homeMatchLabel
            }

            Section("Notes") {
                TextEditor(text: binding(\.notes))
                    .frame(minHeight: 70)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    /// Live feedback on the scope: does the pattern the user is typing actually match
    /// the page the app opens on? A boost that silently matches nothing is the most
    /// confusing thing this editor could do.
    private var homeMatchLabel: some View {
        let matches = BoostMatcher.matches(boost.match, url: wrap.homeURL)
        let host = URLNormalizer.displayString(for: wrap.homeURL)
        return Label(matches ? "Yes — \(host)" : "No — \(host)",
                     systemImage: matches ? "checkmark.circle.fill" : "xmark.circle")
            .foregroundStyle(matches ? Color.green : Color.secondary)
    }

    private var patternPrompt: String {
        switch boost.match.kind {
        case .everywhere: return ""
        case .domain: return wrap.homeHost
        case .urlPrefix: return wrap.homeURL.absoluteString
        case .glob: return "https://\(wrap.homeHost)/*/settings"
        case .regex: return #"/inbox/\d+"#
        }
    }

    // MARK: Bindings

    private func binding<Value>(_ keyPath: WritableKeyPath<Boost, Value>) -> Binding<Value> {
        Binding(
            get: { boost[keyPath: keyPath] },
            set: { newValue in
                var updated = boost
                updated[keyPath: keyPath] = newValue
                model.updateBoost(updated, in: wrap)
            })
    }

    private func themeBinding<Value>(_ keyPath: WritableKeyPath<BoostTheme, Value>) -> Binding<Value> {
        binding((\Boost.theme).appending(path: keyPath))
    }

    private func matchBinding<Value>(_ keyPath: WritableKeyPath<BoostMatch, Value>) -> Binding<Value> {
        binding((\Boost.match).appending(path: keyPath))
    }

    /// A `String` binding over an optional field, where empty means "leave the site's
    /// own value alone".
    private func optionalStringBinding(
        _ keyPath: WritableKeyPath<BoostTheme, String?>) -> Binding<String> {
        let inner = themeBinding(keyPath)
        return Binding(
            get: { inner.wrappedValue ?? "" },
            set: { inner.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    // MARK: Controls

    /// A colour row with an explicit on/off, because "no override" is a distinct state
    /// from "override with black" and a bare `ColorPicker` can't express it.
    private func optionalColor(_ label: String,
                               keyPath: WritableKeyPath<BoostTheme, String?>) -> some View {
        let stored = themeBinding(keyPath)
        let isOn = Binding(
            get: { stored.wrappedValue != nil },
            set: { stored.wrappedValue = $0 ? (stored.wrappedValue ?? "#1E1E1E") : nil })
        let color = Binding(
            get: { Color(hexString: stored.wrappedValue ?? "#1E1E1E") },
            set: { stored.wrappedValue = $0.hexString })

        return HStack {
            Toggle("", isOn: isOn).labelsHidden()
            Text(label)
            Spacer()
            if stored.wrappedValue != nil {
                ColorPicker("", selection: color, supportsOpacity: true)
                    .labelsHidden()
            } else {
                Text("Unchanged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func optionalNumber(_ label: String,
                                keyPath: WritableKeyPath<BoostTheme, Double?>,
                                range: ClosedRange<Double>,
                                suffix: String) -> some View {
        let stored = themeBinding(keyPath)
        let isOn = Binding(
            get: { stored.wrappedValue != nil },
            set: { stored.wrappedValue = $0 ? (stored.wrappedValue ?? range.lowerBound) : nil })
        let value = Binding(
            get: { stored.wrappedValue ?? range.lowerBound },
            set: { stored.wrappedValue = $0 })

        return HStack {
            Toggle("", isOn: isOn).labelsHidden()
            Text(label)
            if stored.wrappedValue != nil {
                Slider(value: value, in: range)
                Text("\(Int(value.wrappedValue.rounded()))\(suffix)")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                    .foregroundStyle(.secondary)
            } else {
                Spacer()
                Text("Unchanged")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>,
                        range: ClosedRange<Double>, percent: Bool,
                        suffix: String = "") -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%"
                 : "\(formatted(value.wrappedValue))\(suffix)")
                .monospacedDigit()
                .frame(width: 52, alignment: .trailing)
                .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ value: Double) -> String {
        BoostCSSGenerator.number((value * 100).rounded() / 100)
    }

    // MARK: Mutations

    private func removeSelector(at index: Int) {
        var updated = boost
        guard updated.zapSelectors.indices.contains(index) else { return }
        updated.zapSelectors.remove(at: index)
        model.updateBoost(updated, in: wrap)
    }

    private func resetTheme() {
        var updated = boost
        updated.theme = .neutral
        model.updateBoost(updated, in: wrap)
    }
}
