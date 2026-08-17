import Foundation

/// The JavaScript the runtime injects.
///
/// Kept as Swift raw-string literals rather than `.js` resource files on purpose: a
/// generated app's bundle is written by `AppBundleWriter`, which copies **only** the
/// executable out of Wrapybara. A resource file would have to be copied too and kept
/// in step; compiled-in strings simply cannot go missing.
///
/// Every script is wrapped in an IIFE and namespaced under `window.__wrapybara`, so
/// nothing here can collide with the page's own globals.
enum BoostScripts {

    /// The message-handler names registered on the web view. The page can post to
    /// these, so they're deliberately few and each one validates its payload.
    enum Handler {
        /// The element picker reporting a chosen selector.
        static let picker = "wrapybaraPicker"
        /// The `Notification` shim forwarding a notification.
        static let notification = "wrapybaraNotification"
        /// A boost's stylesheet asking to be re-applied after a soft navigation.
        static let navigated = "wrapybaraNavigated"
    }

    /// The `<style>` element id the boost stylesheet lives in.
    static let styleElementID = "wrapybara-boost-style"

    // MARK: Stylesheet application

    /// Installs (or replaces) the boost stylesheet.
    ///
    /// Injected at `documentStart` so the page is styled before first paint, which is
    /// what keeps a dark boost from flashing white. Because `documentStart` runs
    /// before `<head>` exists, it retries on `DOMContentLoaded`.
    ///
    /// The element is re-appended if the page removes it, and re-appended *last* so a
    /// site that adds stylesheets after load doesn't quietly outrank the boost.
    static func applyStylesheet(_ css: String) -> String {
        let literal = jsStringLiteral(css)
        return #"""
        (function () {
          var ns = window.__wrapybara = window.__wrapybara || {};
          ns.css = \#(literal);
          ns.styleID = "\#(styleElementID)";

          function install() {
            var head = document.head || document.documentElement;
            if (!head) { return false; }
            var existing = document.getElementById(ns.styleID);
            if (existing) {
              if (existing.textContent !== ns.css) { existing.textContent = ns.css; }
              // Keep it last so later-added site stylesheets don't win on equal
              // specificity.
              if (head.lastChild !== existing) { head.appendChild(existing); }
              return true;
            }
            var style = document.createElement("style");
            style.id = ns.styleID;
            style.setAttribute("type", "text/css");
            style.textContent = ns.css;
            head.appendChild(style);
            return true;
          }

          if (!install()) {
            document.addEventListener("DOMContentLoaded", install, { once: true });
          }

          // Single-page apps replace the whole DOM without a navigation, which can
          // take the style element with it. One observer on <html>, childList only,
          // is cheap; a full subtree observer on a busy app is not.
          if (!ns.styleObserver && document.documentElement) {
            ns.styleObserver = new MutationObserver(function () {
              if (!document.getElementById(ns.styleID)) { install(); }
            });
            ns.styleObserver.observe(document.documentElement, { childList: true, subtree: false });
          }
        })();
        """#
    }

    // MARK: Element picker

    /// The Zap picker: hover to highlight, click to select, ↑/↓ to widen or narrow
    /// the selection to an ancestor or back, Esc to cancel.
    ///
    /// Reports the chosen CSS selector back over the `picker` message handler. The
    /// widen-to-ancestor step is what Arc calls "zap all related elements": one
    /// element is rarely what you mean — you meant its container.
    static var elementPicker: String {
        #"""
        (function () {
          var ns = window.__wrapybara = window.__wrapybara || {};
          if (ns.picker && ns.picker.active) { return; }

          var overlay = document.createElement("div");
          overlay.setAttribute("data-wrapybara-picker", "1");
          overlay.style.cssText = [
            "position:fixed", "pointer-events:none", "z-index:2147483647",
            "border:2px solid #8B5A2B", "background:rgba(139,90,43,0.18)",
            "border-radius:3px", "transition:none", "box-sizing:border-box"
          ].join(";");

          var label = document.createElement("div");
          label.setAttribute("data-wrapybara-picker", "1");
          label.style.cssText = [
            "position:fixed", "pointer-events:none", "z-index:2147483647",
            "font:11px ui-monospace,SFMono-Regular,Menlo,monospace",
            "background:#8B5A2B", "color:#fff", "padding:3px 6px",
            "border-radius:4px", "max-width:60vw", "overflow:hidden",
            "text-overflow:ellipsis", "white-space:nowrap"
          ].join(";");

          var current = null;   // the element under the cursor
          var target = null;    // current, or an ancestor after ↑
          var depth = 0;

          function isOurs(node) {
            return node && node.nodeType === 1 && node.hasAttribute &&
                   node.hasAttribute("data-wrapybara-picker");
          }

          function resolveTarget() {
            var node = current;
            for (var i = 0; i < depth && node && node.parentElement; i++) {
              // Never widen past <body>: selecting it would hide the whole page.
              if (node.parentElement === document.body) { break; }
              node = node.parentElement;
            }
            return node;
          }

          function paint() {
            target = resolveTarget();
            if (!target) { return; }
            var box = target.getBoundingClientRect();
            overlay.style.top = box.top + "px";
            overlay.style.left = box.left + "px";
            overlay.style.width = box.width + "px";
            overlay.style.height = box.height + "px";
            var text = ns.selectorFor(target);
            label.textContent = text + (depth > 0 ? "  ↑" + depth : "");
            // Put the label above the box, or below it when there's no room.
            var top = box.top - 22;
            label.style.top = (top < 4 ? box.bottom + 4 : top) + "px";
            label.style.left = Math.max(4, box.left) + "px";
          }

          function onMove(event) {
            var node = document.elementFromPoint(event.clientX, event.clientY);
            if (!node || isOurs(node) || node === current) { return; }
            current = node;
            depth = 0;
            paint();
          }

          function onKey(event) {
            if (event.key === "Escape") { finish(null); }
            else if (event.key === "ArrowUp") { depth += 1; paint(); }
            else if (event.key === "ArrowDown") { depth = Math.max(0, depth - 1); paint(); }
            else { return; }
            event.preventDefault();
            event.stopPropagation();
          }

          function onClick(event) {
            event.preventDefault();
            event.stopPropagation();
            finish(target ? ns.selectorFor(target) : null);
          }

          function finish(selector) {
            ns.picker.active = false;
            window.removeEventListener("mousemove", onMove, true);
            window.removeEventListener("click", onClick, true);
            window.removeEventListener("keydown", onKey, true);
            window.removeEventListener("scroll", paint, true);
            if (overlay.parentNode) { overlay.parentNode.removeChild(overlay); }
            if (label.parentNode) { label.parentNode.removeChild(label); }
            try {
              window.webkit.messageHandlers.\#(Handler.picker).postMessage({
                selector: selector || ""
              });
            } catch (error) { /* the handler is gone; nothing to report to */ }
          }

          ns.picker = { active: true, cancel: function () { finish(null); } };
          document.documentElement.appendChild(overlay);
          document.documentElement.appendChild(label);
          // Capture-phase listeners so the page's own handlers never see the click
          // that picks an element.
          window.addEventListener("mousemove", onMove, true);
          window.addEventListener("click", onClick, true);
          window.addEventListener("keydown", onKey, true);
          window.addEventListener("scroll", paint, true);
        })();
        """#
    }

    /// Builds a CSS selector for an element.
    ///
    /// Installed separately from the picker because the boost editor's live preview
    /// uses it too. The ladder is: an id if it looks authored rather than generated,
    /// then stable-looking classes, then a positional path — and it stops as soon as
    /// the selector is unique, so the result is as short as it can be.
    static var selectorBuilder: String {
        #"""
        (function () {
          var ns = window.__wrapybara = window.__wrapybara || {};
          if (ns.selectorFor) { return; }

          // Framework-generated identifiers change on every build or render, so a
          // selector built from one would stop matching. These are the shapes the
          // common bundlers and CSS-in-JS libraries emit.
          function looksGenerated(token) {
            if (!token || token.length > 40) { return true; }
            if (/^[0-9]/.test(token)) { return true; }
            if (/^(css|sc|jsx|emotion|svelte|ng|mui)-[0-9a-z]{4,}$/i.test(token)) { return true; }
            if (/^[a-z]*[0-9a-f]{6,}$/i.test(token)) { return true; }   // hash-like
            if (/[0-9]{4,}/.test(token)) { return true; }
            if (/^(ember|react|vue)[0-9]+/i.test(token)) { return true; }
            return false;
          }

          function escape(value) {
            if (window.CSS && window.CSS.escape) { return window.CSS.escape(value); }
            return String(value).replace(/[^a-zA-Z0-9_-]/g, function (character) {
              return "\\" + character;
            });
          }

          function unique(selector, node) {
            try {
              var found = document.querySelectorAll(selector);
              return found.length === 1 && found[0] === node;
            } catch (error) { return false; }
          }

          function part(node) {
            var tag = node.tagName ? node.tagName.toLowerCase() : "*";
            if (node.id && !looksGenerated(node.id)) { return "#" + escape(node.id); }

            var classes = [];
            if (node.classList) {
              for (var i = 0; i < node.classList.length && classes.length < 3; i++) {
                var token = node.classList[i];
                if (!looksGenerated(token)) { classes.push("." + escape(token)); }
              }
            }
            if (classes.length) { return tag + classes.join(""); }

            // Nothing stable to hold on to: fall back to position among siblings.
            var index = 1;
            var sibling = node;
            while ((sibling = sibling.previousElementSibling)) {
              if (sibling.tagName === node.tagName) { index++; }
            }
            return tag + ":nth-of-type(" + index + ")";
          }

          ns.selectorFor = function (node) {
            if (!node || node.nodeType !== 1) { return ""; }
            if (node === document.body) { return "body"; }

            var pieces = [];
            var walker = node;
            // Ten levels is deep enough for any real page and short enough that the
            // selector stays readable in the boost editor.
            for (var depth = 0; walker && walker !== document.body && depth < 10; depth++) {
              pieces.unshift(part(walker));
              var candidate = pieces.join(" > ");
              if (unique(candidate, node)) { return candidate; }
              walker = walker.parentElement;
            }
            return pieces.length ? pieces.join(" > ") : "";
          };
        })();
        """#
    }

    // MARK: Notification bridge

    /// Replaces the page's `Notification` with one that forwards to macOS.
    ///
    /// `WKWebView` implements no part of the Notifications API, so a web app that
    /// posts notifications is simply silent inside a wrapper. This shim gives it a
    /// `Notification` that looks real enough to use — constructor, `permission`,
    /// `requestPermission`, `onclick` — and posts the payload to the native side.
    ///
    /// Only installed when the wrap asks for it: replacing a page global is intrusive,
    /// and a site that feature-detects `Notification` will start asking for permission
    /// it previously knew it couldn't have.
    static var notificationShim: String {
        #"""
        (function () {
          var ns = window.__wrapybara = window.__wrapybara || {};
          if (ns.notificationShimInstalled) { return; }
          ns.notificationShimInstalled = true;

          var callbacks = {};
          var nextID = 1;

          ns.notificationClicked = function (id) {
            var entry = callbacks[id];
            if (!entry) { return; }
            delete callbacks[id];
            try {
              if (typeof entry.onclick === "function") { entry.onclick.call(entry.notification); }
            } catch (error) { /* the page's handler threw; not our problem to fix */ }
          };

          function ShimNotification(title, options) {
            options = options || {};
            this.title = String(title == null ? "" : title);
            this.body = String(options.body == null ? "" : options.body);
            this.tag = options.tag ? String(options.tag) : "";
            this.silent = !!options.silent;
            this.onclick = null;
            this.onclose = null;
            this.onerror = null;
            this.onshow = null;

            var id = nextID++;
            var self = this;
            callbacks[id] = { notification: self, get onclick() { return self.onclick; } };
            try {
              window.webkit.messageHandlers.\#(Handler.notification).postMessage({
                id: id, title: this.title, body: this.body, tag: this.tag, silent: this.silent
              });
            } catch (error) { /* no native side; behave like a no-op notification */ }
            if (typeof this.onshow === "function") {
              try { this.onshow(); } catch (error) { /* ignore */ }
            }
          }

          ShimNotification.prototype.close = function () {
            if (typeof this.onclose === "function") {
              try { this.onclose(); } catch (error) { /* ignore */ }
            }
          };
          ShimNotification.prototype.addEventListener = function (type, handler) {
            if (type === "click") { this.onclick = handler; }
            else if (type === "close") { this.onclose = handler; }
            else if (type === "show") { this.onshow = handler; }
            else if (type === "error") { this.onerror = handler; }
          };
          ShimNotification.prototype.removeEventListener = function (type) {
            if (type === "click") { this.onclick = null; }
            else if (type === "close") { this.onclose = null; }
            else if (type === "show") { this.onshow = null; }
            else if (type === "error") { this.onerror = null; }
          };

          // The native side has already been granted (or denied) permission by the
          // user in System Settings, so from the page's point of view it is settled.
          ShimNotification.permission = "granted";
          ShimNotification.maxActions = 0;
          ShimNotification.requestPermission = function (callback) {
            if (typeof callback === "function") { callback("granted"); }
            return Promise.resolve("granted");
          };

          try {
            Object.defineProperty(window, "Notification", {
              value: ShimNotification, writable: true, configurable: true
            });
          } catch (error) {
            window.Notification = ShimNotification;
          }
        })();
        """#
    }

    // MARK: Soft-navigation reporting

    /// Reports History API navigations to the native side.
    ///
    /// A single-page app changes its URL without any `WKNavigationDelegate` callback,
    /// so without this the toolbar's URL, the back/forward state and — most
    /// importantly — *which boosts apply* would all go stale the moment the user
    /// clicked around inside the app.
    static var navigationReporter: String {
        #"""
        (function () {
          var ns = window.__wrapybara = window.__wrapybara || {};
          if (ns.navigationReporterInstalled) { return; }
          ns.navigationReporterInstalled = true;

          var lastReported = "";
          function report() {
            var href = location.href;
            if (href === lastReported) { return; }
            lastReported = href;
            try {
              window.webkit.messageHandlers.\#(Handler.navigated).postMessage({
                url: href, title: document.title || ""
              });
            } catch (error) { /* nothing listening */ }
          }

          ["pushState", "replaceState"].forEach(function (name) {
            var original = history[name];
            if (typeof original !== "function") { return; }
            history[name] = function () {
              var result = original.apply(this, arguments);
              // After the frame, so `location.href` reflects the change.
              setTimeout(report, 0);
              return result;
            };
          });
          window.addEventListener("popstate", function () { setTimeout(report, 0); });
          window.addEventListener("hashchange", function () { setTimeout(report, 0); });
          report();
        })();
        """#
    }

    // MARK: Helpers

    /// A JavaScript string literal for `value`, safe to paste into a script.
    ///
    /// JSON is a subset of JavaScript expression syntax for strings, so
    /// `JSONSerialization` does the escaping — including `</script>`-unsafe sequences,
    /// which don't matter here (nothing is injected into markup) but keep the output
    /// safe if that ever changes.
    static func jsStringLiteral(_ value: String) -> String {
        // `.fragmentsAllowed` lets a bare string be encoded without wrapping it in an
        // array or object first.
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
           let literal = String(data: data, encoding: .utf8) {
            return literal
        }
        // Encoding a `String` can't realistically fail, but a stylesheet that silently
        // became `""` would be a mystifying bug — so fall back to hand-escaping the
        // characters that actually matter.
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(escaped)\""
    }
}
