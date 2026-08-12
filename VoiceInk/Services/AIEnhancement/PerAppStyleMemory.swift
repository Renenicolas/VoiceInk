import Foundation
import CryptoKit
import Security
import os

/// Learns how the user writes in each app (keyed by bundle id) from past AI-enhanced
/// dictation output, so future enhancements in that app can match their established style.
///
/// STRICT PRIVACY: storage is local-only and encrypted at rest — nothing here ever touches
/// the network. The AES-GCM key lives in the real macOS Keychain (raw `SecItem` calls,
/// `kSecClassGenericPassword`) — deliberately NOT via `KeychainService`, whose `LOCAL_BUILD`
/// path stores secrets as plaintext in `UserDefaults`; an encryption key must never be
/// recoverable as plaintext. The key is `ThisDeviceOnly` and never marked synchronizable, so
/// it never leaves this Mac — not even via iCloud Keychain.
///
/// Note on local (ad-hoc signed) builds: macOS Keychain ACLs can be bound to the creating
/// app's code signature, and an ad-hoc signature can change across rebuilds — in the worst
/// case that could make a previously-stored key unreadable (or trigger a one-time system
/// "allow access" prompt) after a rebuild. That's a deliberate, accepted trade-off
/// (`KeychainService` avoids it for API keys via its plaintext fallback; we refuse that
/// fallback here). If the key can't be read, `load()` treats the on-disk ciphertext as
/// unrecoverable and starts fresh rather than crashing or falling back to plaintext.
final class PerAppStyleMemory {
    static let shared = PerAppStyleMemory()

    /// Max exemplars retained per app.
    private static let maxExemplarsPerApp = 8
    /// Rolling char budget per app; oldest exemplars are evicted first when exceeded.
    private static let maxCharsPerApp = 6000
    /// Cap on a single exemplar so one huge output can't blow the whole app budget.
    private static let maxCharsPerExemplar = 2000
    /// Cap on the number of distinct apps tracked at all — per-app entries are bounded above,
    /// but without this the map of apps itself grows unbounded (one bucket per foreground app
    /// ever seen). Oldest-touched app is evicted first once exceeded.
    private static let maxApps = 50

    /// Matches the `@AppStorage` key used by the Settings toggle.
    static let isEnabledKey = "PerAppStyleMemoryEnabled"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PerAppStyleMemory")
    private let lock = NSLock()
    /// On-disk shape: `order` tracks apps oldest-touched-first (see `maxApps` eviction);
    /// `entries` is the same per-app exemplar map `cache` always was.
    private struct PersistedState: Codable {
        var order: [String]
        var entries: [String: [String]]
    }

    private let storeURL: URL?
    private var cache: [String: [String]]
    /// Distinct app keys, oldest-touched first. `record` moves an app to the end.
    private var appOrder: [String]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.isEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.isEnabledKey) }
    }

    private init() {
        storeURL = Self.resolveStoreURL()
        cache = [:]
        appOrder = []
        let state = load()
        cache = state.entries
        appOrder = state.order
    }

    // MARK: - Public API

    /// Records a finished AI-enhancement output as a style exemplar for `bundleID`.
    /// No-ops when memory is disabled, the output is empty, or the app is unknown.
    func record(output: String, forApp bundleID: String) {
        guard isEnabled else { return }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !bundleID.isEmpty else { return }

        // Sanitized so a captured page/clipboard that made it into the enhanced output can't
        // later poison a future prompt when this exemplar is replayed back into it.
        let sanitized = PromptTagSanitizer.sanitize(
            PromptTagSanitizer.truncate(trimmed, limit: Self.maxCharsPerExemplar)
        )

        lock.lock()
        defer { lock.unlock() }

        var exemplars = cache[bundleID] ?? []
        exemplars.append(sanitized)
        while exemplars.count > Self.maxExemplarsPerApp {
            exemplars.removeFirst()
        }
        while exemplars.count > 1, exemplars.reduce(0, { $0 + $1.count }) > Self.maxCharsPerApp {
            exemplars.removeFirst()
        }
        cache[bundleID] = exemplars

        appOrder.removeAll { $0 == bundleID }
        appOrder.append(bundleID)
        while appOrder.count > Self.maxApps {
            let evicted = appOrder.removeFirst()
            cache[evicted] = nil
        }

        persist()
    }

    /// Recent exemplars for `bundleID`, oldest first. Empty when memory is disabled or unknown.
    func recentExemplars(forApp bundleID: String) -> [String] {
        guard isEnabled else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return cache[bundleID] ?? []
    }

    func clear(forApp bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard cache[bundleID] != nil else { return }
        cache[bundleID] = nil
        appOrder.removeAll { $0 == bundleID }
        persist()
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !cache.isEmpty else { return }
        cache = [:]
        appOrder = []
        persist()
    }

    // MARK: - Persistence (encrypted at rest, local only)

    private static func resolveStoreURL() -> URL? {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = appSupport.appendingPathComponent("com.prakashjoshipax.VoiceInk")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("PerAppStyleMemory.enc")
    }

    private func load() -> PersistedState {
        let empty = PersistedState(order: [], entries: [:])
        guard let storeURL, FileManager.default.fileExists(atPath: storeURL.path) else { return empty }
        guard let key = existingKey() else {
            logger.error("Per-app style memory ciphertext exists but its Keychain key is unavailable; starting fresh")
            return empty
        }
        do {
            let sealedData = try Data(contentsOf: storeURL)
            let sealedBox = try AES.GCM.SealedBox(combined: sealedData)
            let plaintext = try AES.GCM.open(sealedBox, using: key)
            if let state = try? JSONDecoder().decode(PersistedState.self, from: plaintext) {
                return state
            }
            // Back-compat: pre-L1 files stored the raw `[String: [String]]` map with no order.
            let legacyEntries = try JSONDecoder().decode([String: [String]].self, from: plaintext)
            return PersistedState(order: Array(legacyEntries.keys), entries: legacyEntries)
        } catch {
            logger.error("Failed to decrypt per-app style memory, starting fresh: \(error, privacy: .public)")
            return empty
        }
    }

    private func persist() {
        guard let storeURL else { return }
        guard let key = existingKey() ?? generateAndStoreKey() else {
            logger.error("No encryption key available; not persisting per-app style memory")
            return
        }
        do {
            let plaintext = try JSONEncoder().encode(PersistedState(order: appOrder, entries: cache))
            let sealedBox = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealedBox.combined else {
                logger.error("AES-GCM seal produced no combined representation")
                return
            }
            try combined.write(to: storeURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        } catch {
            logger.error("Failed to persist per-app style memory: \(error, privacy: .public)")
        }
    }

    // MARK: - Key management (real Keychain — never plaintext, never synced off-device)

    private func existingKey() -> SymmetricKey? {
        var query = baseKeyQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private func generateAndStoreKey() -> SymmetricKey? {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }

        SecItemDelete(baseKeyQuery() as CFDictionary)

        var query = baseKeyQuery()
        query[kSecValueData as String] = keyData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("Failed to store per-app style memory encryption key in Keychain, status: \(status, privacy: .public)")
            return nil
        }
        return key
    }

    /// Deliberately the classic file-based generic-password keychain, NOT
    /// `kSecUseDataProtectionKeychain`: the data-protection keychain requires a
    /// `keychain-access-groups`/application-identifier entitlement this app doesn't carry
    /// (verified: `SecItemAdd` fails with `errSecMissingEntitlement` under ad-hoc/local
    /// signing without it), so it would silently fail to persist the key on local builds.
    /// The classic keychain needs no such entitlement and is still the real macOS Keychain.
    /// `kSecAttrSynchronizable` is deliberately omitted (defaults to non-synchronizable) and
    /// accessibility is `ThisDeviceOnly` — this key must never leave this Mac.
    private func baseKeyQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.prakashjoshipax.VoiceInk.PerAppStyleMemory",
            kSecAttrAccount as String: "encryptionKey"
        ]
    }
}
