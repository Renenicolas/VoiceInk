import Foundation

/// Resolves the storage key `PerAppStyleMemory` learns/injects a voice profile under.
///
/// Previously that key was always the frontmost app's bundle id — which meant every website
/// visited inside one browser (Gmail, Docs, a work EMR, ...) shared a single "Chrome" profile.
/// Now: when the frontmost app is a known browser (see `BrowserType`) and its active tab's URL
/// is available, the key is `"web:<domain>"` — so different sites get their own learned voice.
/// Everything else (native apps, or a browser whose URL couldn't be fetched) keeps the app key,
/// `"app:<bundleID>"`. The two are prefixed so a domain can never collide with a bundle id.
///
/// `PerAppStyleMemory` itself is unchanged — it has always just been a `[String: ...]` store
/// keyed by an opaque string; only what callers pass in as that string changes here.
enum StyleContextKeyResolver {
    static let webPrefix = "web:"
    static let appPrefix = "app:"

    /// Pure key computation: given the frontmost app's bundle id and — only relevant when that
    /// app is a known browser — its active tab's URL, returns the storage key. No I/O, so this
    /// is what's unit tested directly; `resolve(bundleID:)` below is the thin async wrapper that
    /// fetches `browserTabURL` for real recordings.
    static func key(bundleID: String, browserTabURL: String?) -> String {
        guard BrowserType.allCases.contains(where: { $0.bundleIdentifier == bundleID }),
              let browserTabURL,
              let domain = domain(from: browserTabURL) else {
            return appPrefix + bundleID
        }
        return webPrefix + domain
    }

    /// Resolves `bundleID`'s style-context key at recording time, fetching the active browser
    /// tab's URL via `BrowserURLService` when `bundleID` is a known browser. Falls back to the
    /// app key on any failure — browser not running, AppleScript error/timeout, no active tab —
    /// same as a native app. `nil` only when `bundleID` itself is nil/empty (unknown frontmost
    /// app).
    static func resolve(bundleID: String?) async -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        guard let browserType = BrowserType.allCases.first(where: { $0.bundleIdentifier == bundleID }) else {
            return appPrefix + bundleID
        }
        let url = try? await BrowserURLService.shared.getCurrentURL(from: browserType)
        return key(bundleID: bundleID, browserTabURL: url)
    }

    /// Lowercased host with a leading "www." stripped, e.g.
    /// `"https://mail.google.com/mail/u/0"` -> `"mail.google.com"`. Subdomains are kept as-is
    /// (mail.google.com and docs.google.com stay distinct — that's the point). `URL(string:)`
    /// only parses `host` reliably when a scheme is present, so one is added if missing (a bare
    /// "localhost:3000" style value still resolves to a usable, if unusual, domain key).
    static func domain(from urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URL(string: withScheme)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
