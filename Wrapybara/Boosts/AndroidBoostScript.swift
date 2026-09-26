import Foundation
import JavaScriptCore

/// Bakes existing CSS output into a main-frame, post-load Android script.
enum AndroidBoostScript {
    private enum ScriptError: LocalizedError {
        case validationUnavailable
        case invalidJavaScript(name: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .validationUnavailable:
                return "JavaScript validation could not start. Try exporting again."
            case .invalidJavaScript(let name, let reason):
                return "Fix the JavaScript in Boost \"\(name)\" before exporting: \(reason)"
            }
        }
    }

    static func make(boosts: [Boost]) throws -> [String] {
        let enabled = boosts.filter { $0.isEnabled && !$0.isEmpty }
        let payload: [[String: Any]] = enabled.map { boost in
            var pattern = boost.match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            if boost.match.kind == .domain { pattern = BoostMatcher.normalizedHost(pattern) }
            return [
                "id": boost.id.uuidString,
                "kind": boost.match.kind.rawValue,
                "pattern": pattern,
                "subdomains": boost.match.includesSubdomains,
                "caseSensitive": boost.match.isCaseSensitive,
                "css": BoostCSSGenerator.stylesheet(for: boost),
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        let bootstrap = #"""
        (function () {
          'use strict';
          if (!/^https?:$/.test(location.protocol)) return;
          if (window.__wrapybaraAndroid) { window.__wrapybaraAndroid.apply(); return; }
          const boosts = \#(json);
          const styleID = '__wrapybara_android_style';
          const executed = new Set();
          const scripts = new Map();

          function matches(boost) {
            const pattern = boost.pattern;
            switch (boost.kind) {
              case 'everywhere': return true;
              case 'domain':
                return pattern !== '' && (location.hostname.toLowerCase() === pattern ||
                  (boost.subdomains && location.hostname.toLowerCase().endsWith('.' + pattern)));
              case 'urlPrefix': return pattern !== '' && location.href.startsWith(pattern);
              case 'glob':
              case 'regex':
                if (!pattern) return false;
                try {
                  const expression = boost.kind === 'glob'
                    ? '^' + Array.from(pattern).map(c => c === '*' ? '.*' : c === '?' ? '.' :
                        c.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('') + '$'
                    : pattern;
                  return new RegExp(expression, boost.caseSensitive ? '' : 'i').test(location.href);
                } catch (_) { return false; }
              default: return false;
            }
          }

          function apply() {
            const applicable = boosts.filter(matches);
            let style = document.getElementById(styleID);
            if (!style) {
              style = document.createElement('style');
              style.id = styleID;
              (document.head || document.documentElement).appendChild(style);
            }
            style.textContent = applicable.map(b => b.css).join('\n');
            for (const boost of applicable) {
              const run = scripts.get(boost.id);
              if (!run || executed.has(boost.id)) continue;
              executed.add(boost.id);
              try { run.call(window); } catch (error) {
                console.warn('Wrapybara Boost failed', error);
              }
            }
          }

          // Rescope CSS on SPA navigation; a trusted script runs once per document.
          window.__wrapybaraAndroid = {
            apply: apply,
            register: function (id, run) {
              if (!scripts.has(id)) scripts.set(id, run);
              apply();
            }
          };
          for (const method of ['pushState', 'replaceState']) {
            const original = history[method];
            history[method] = function () {
              const result = original.apply(this, arguments);
              apply();
              return result;
            };
          }
          window.addEventListener('popstate', apply);
          window.addEventListener('hashchange', apply);
          apply();
        })();
        """#

        // Native evaluation avoids page CSP's eval restriction. Separate sources
        // keep one script's syntax error from disabling CSS or another script.
        let scripts = try enabled.compactMap { boost -> String? in
            guard boost.hasRunnableJavaScript, boost.javaScriptInjectionTime == .documentEnd else { return nil }
            try validateScript(boost)
            let identifier = BoostScripts.jsStringLiteral(boost.id.uuidString)
            return #"""
            (function () {
              if (!window.__wrapybaraAndroid) return;
              window.__wrapybaraAndroid.register(\#(identifier), function () {
            \#(boost.javaScript)
              });
            })();
            """#
        }
        return [bootstrap] + scripts
    }

    private static func validateScript(_ boost: Boost) throws {
        guard let context = JSContext() else { throw ScriptError.validationUnavailable }

        // Compile only. A valid function body cannot close its scope wrapper early.
        let function = context.objectForKeyedSubscript("Function")?
            .construct(withArguments: [boost.javaScript])
        guard function?.isObject == true, context.exception == nil else {
            throw ScriptError.invalidJavaScript(name: boost.name,
                                               reason: context.exception?.toString() ?? "Invalid syntax")
        }
    }
}
