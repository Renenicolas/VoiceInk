import Foundation
import AppKit

/// Notify-only update check against the CRM's public release feed.
///
/// This NEVER downloads or installs anything. It only fetches a small JSON payload,
/// compares it against the running version (the CRM does the actual semver compare —
/// see its `updateAvailable` field), and — if a newer build is published — shows a
/// dismissible banner plus a persistent menu-bar item, both of which just open the
/// gated CRM downloads page in the user's browser.
///
/// Sparkle's auto-updater (see `UpdaterViewModel` in VoiceInk.swift) is intentionally
/// disabled and is untouched by this service — this is a separate, purely informational
/// path.
final class UpdateCheckService: ObservableObject {
    static let shared = UpdateCheckService()

    /// Set when the CRM reports a newer version than the one currently running.
    /// MenuBarView observes this to show a persistent "Update available" item.
    @Published private(set) var availableUpdate: AvailableUpdate?

    struct AvailableUpdate {
        let version: String
        let critical: Bool
        let downloadURL: URL
    }

    private init() {}

    // MARK: - Configuration

    /// Overridable via UserDefaults for staging/testing without a rebuild.
    /// TODO: replace with the real production CRM host once it's live.
    // No default host: until a real Nino CRM URL is configured (via NinoUpdateFeedBase),
    // the app makes NO update-check request. A hardcoded host we don't own would ping a
    // third party on every launch. Empty = no request.
    private static let defaultFeedBase = ""
    private static let feedBaseDefaultsKey = "NinoUpdateFeedBase"
    private static let lastCheckDefaultsKey = "NinoLastUpdateCheckDate"

    /// User-facing "Check for updates" preference (Settings). Default true.
    static let enabledDefaultsKey = "NinoVoiceCheckForUpdates"

    private let product = "nino-voice"
    private let platform = "mac"
    private let minCheckInterval: TimeInterval = 6 * 60 * 60
    private let requestTimeout: TimeInterval = 10

    private var feedBase: String {
        UserDefaults.standard.string(forKey: Self.feedBaseDefaultsKey) ?? Self.defaultFeedBase
    }

    // MARK: - Public API

    /// Call once on launch. No-ops silently if the user disabled checks, if the last
    /// check was within `minCheckInterval`, or on any network/parsing failure — this
    /// must never surface an error or interrupt the user.
    func checkOnLaunchIfNeeded() {
        // AppDefaults.registerDefaults() runs before this is ever called, so the
        // registered default (true) is what bool(forKey:) returns until the user
        // flips the Settings toggle.
        guard UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) else { return }

        if let last = UserDefaults.standard.object(forKey: Self.lastCheckDefaultsKey) as? Date,
           Date().timeIntervalSince(last) < minCheckInterval {
            return
        }

        performCheck()
    }

    // MARK: - Core logic

    private func performCheck() {
        guard let url = buildRequestURL() else { return }

        UserDefaults.standard.set(Date(), forKey: Self.lastCheckDefaultsKey)

        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard error == nil, let data else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return }
            guard let payload = try? JSONDecoder().decode(AppVersionResponse.self, from: data) else { return }
            guard payload.updateAvailable else { return }
            guard let downloadURL = self.downloadPageURL() else { return }

            let update = AvailableUpdate(version: payload.latest, critical: payload.critical, downloadURL: downloadURL)
            DispatchQueue.main.async {
                self.availableUpdate = update
                self.showBanner(for: update)
            }
        }
        task.resume()
    }

    private func buildRequestURL() -> URL? {
        let base = feedBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, base.hasPrefix("https://") else { return nil }
        var components = URLComponents(string: "\(base)/api/app-version")
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        components?.queryItems = [
            URLQueryItem(name: "product", value: product),
            URLQueryItem(name: "platform", value: platform),
            URLQueryItem(name: "current", value: currentVersion),
        ]
        return components?.url
    }

    /// The friendly, token-gated CRM downloads page — not the raw `downloadPath` API route,
    /// which 401s without a per-client token this app doesn't carry (see the response model's
    /// `downloadPath` doc comment).
    private func downloadPageURL() -> URL? {
        URL(string: "\(feedBase)/downloads")
    }

    /// Opens the CRM downloads page in the default browser. Never touches the app bundle.
    func openDownloadPage() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.downloadURL)
    }

    @MainActor
    private func showBanner(for update: AvailableUpdate) {
        let title = update.critical
            ? String(localized: "Critical update available — v\(update.version)")
            : String(localized: "Update available — v\(update.version)")

        NotificationManager.shared.showNotification(
            title: title,
            type: update.critical ? .warning : .info,
            duration: 10,
            actionButton: (String(localized: "Download"), { [weak self] in
                self?.openDownloadPage()
            })
        )
    }
}

// MARK: - Response model

private struct AppVersionResponse: Decodable {
    let latest: String
    let updateAvailable: Bool
    let critical: Bool
    let notes: String?
    /// Token-gated raw download route (e.g. "/api/downloads/mac"). Decoded for API-contract
    /// completeness but intentionally NOT used to build the opened URL — see downloadPageURL()
    /// — since this app carries no per-client token and that route 401s without one.
    let downloadPath: String
}
