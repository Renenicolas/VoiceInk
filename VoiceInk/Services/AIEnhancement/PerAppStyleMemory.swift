import Foundation
import CryptoKit
import Security
import os

/// What `PerAppStyleMemory.styleMemoryContent(forApp:)` resolved to inject into a prompt.
enum StyleMemoryContent {
    case profile(String)
    case exemplars([String])
    case none
}

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
    /// Cap on a stored/edited profile — a distilled profile is meant to be short; this is
    /// belt-and-suspenders against a runaway CLI response or a huge pasted "teach" sample.
    private static let maxProfileChars = 2000
    /// New exemplars recorded for an app before its profile is re-distilled (see
    /// `PerAppVoiceProfileConsolidator`).
    static let consolidationThreshold = 5

    /// Matches the `@AppStorage` key used by the Settings toggle.
    static let isEnabledKey = "PerAppStyleMemoryEnabled"

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PerAppStyleMemory")
    private let lock = NSLock()
    /// On-disk shape: `order` tracks apps oldest-touched-first (see `maxApps` eviction);
    /// `entries` is the same per-app exemplar map `cache` always was. `profiles` is the
    /// distilled, human-readable per-app voice profile (see `PerAppVoiceProfileService`) —
    /// source material (`entries`) is kept even once a profile exists, so consolidation always
    /// has something to re-distill from. `pendingSinceConsolidation` counts exemplars recorded
    /// since an app's last successful consolidation, independent of `entries`' capped length.
    private struct PersistedState: Codable {
        var order: [String]
        var entries: [String: [String]]
        var profiles: [String: String]
        var pendingSinceConsolidation: [String: Int]

        init(
            order: [String],
            entries: [String: [String]],
            profiles: [String: String] = [:],
            pendingSinceConsolidation: [String: Int] = [:]
        ) {
            self.order = order
            self.entries = entries
            self.profiles = profiles
            self.pendingSinceConsolidation = pendingSinceConsolidation
        }

        // Custom decode so files written before profiles/consolidation existed (missing those
        // keys entirely) still load instead of failing decode.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            order = try container.decode([String].self, forKey: .order)
            entries = try container.decode([String: [String]].self, forKey: .entries)
            profiles = try container.decodeIfPresent([String: String].self, forKey: .profiles) ?? [:]
            pendingSinceConsolidation = try container.decodeIfPresent([String: Int].self, forKey: .pendingSinceConsolidation) ?? [:]
        }
    }

    private let storeURL: URL?
    private var cache: [String: [String]]
    private var profiles: [String: String]
    private var pendingCounts: [String: Int]
    /// Distinct app keys, oldest-touched first. `record`/`setProfile` moves an app to the end.
    private var appOrder: [String]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.isEnabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.isEnabledKey) }
    }

    private init() {
        storeURL = Self.resolveStoreURL()
        cache = [:]
        profiles = [:]
        pendingCounts = [:]
        appOrder = []
        let state = load()
        cache = state.entries
        profiles = state.profiles
        pendingCounts = state.pendingSinceConsolidation
        appOrder = state.order
    }

    // MARK: - Public API

    /// Records a finished AI-enhancement output as a style exemplar for `bundleID`.
    /// No-ops when memory is disabled, the output is empty, or the app is unknown.
    ///
    /// Returns `true` exactly when this call pushed the app's since-last-consolidation
    /// exemplar count to `consolidationThreshold` (and reset it back to 0) — the caller's
    /// signal to kick off a background re-distillation via `PerAppVoiceProfileConsolidator`.
    /// This method itself never calls out to any CLI; it only tracks the counter, so the
    /// trigger point is decided synchronously and cheaply, off of which the caller decides
    /// whether to do the (slow, async) distillation.
    @discardableResult
    func record(output: String, forApp bundleID: String) -> Bool {
        guard isEnabled else { return false }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !bundleID.isEmpty else { return false }

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

        let pending = (pendingCounts[bundleID] ?? 0) + 1
        let shouldConsolidate = pending >= Self.consolidationThreshold
        pendingCounts[bundleID] = shouldConsolidate ? 0 : pending

        touch(bundleID)
        persist()
        return shouldConsolidate
    }

    /// Recent exemplars for `bundleID`, oldest first. Empty when memory is disabled or unknown.
    func recentExemplars(forApp bundleID: String) -> [String] {
        guard isEnabled else { return [] }
        lock.lock()
        defer { lock.unlock() }
        return cache[bundleID] ?? []
    }

    /// The distilled style profile for prompt injection — `nil` when memory is disabled, or
    /// no profile has been distilled yet for this app (raw exemplars are the fallback; see
    /// `AIEnhancementService.styleMemorySection`).
    func profile(forApp bundleID: String) -> String? {
        guard isEnabled else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return profiles[bundleID]
    }

    /// Same as `profile(forApp:)` but ignores the enabled toggle — for the Settings
    /// view/edit/clear UI, which should still show what's stored even while memory is off.
    func rawProfile(forApp bundleID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return profiles[bundleID]
    }

    /// What `AIEnhancementService.styleMemorySection` should inject for `bundleID`: a
    /// distilled profile takes precedence over raw exemplars; raw exemplars are the fallback
    /// until a first profile has been distilled (see `PerAppVoiceProfileConsolidator`).
    /// `.none` when memory is disabled, the app is unknown, or nothing has been recorded yet.
    func styleMemoryContent(forApp bundleID: String?) -> StyleMemoryContent {
        guard isEnabled, let bundleID else { return .none }
        lock.lock()
        defer { lock.unlock() }
        if let profile = profiles[bundleID], !profile.isEmpty {
            return .profile(profile)
        }
        let exemplars = cache[bundleID] ?? []
        return exemplars.isEmpty ? .none : .exemplars(exemplars)
    }

    /// Bundle ids with any stored exemplars and/or a profile, most-recently-touched last.
    /// For the Settings management UI; not gated by the enabled toggle (same reasoning as
    /// `rawProfile`).
    func trackedApps() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return appOrder
    }

    /// Stores (or overwrites) `bundleID`'s distilled profile — called by
    /// `PerAppVoiceProfileConsolidator` after a background re-distillation, and by the
    /// Settings "teach"/edit UI. No-ops on an empty profile or bundle id.
    func setProfile(_ profile: String, forApp bundleID: String) {
        let trimmed = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !bundleID.isEmpty else { return }
        let sanitized = PromptTagSanitizer.sanitize(
            PromptTagSanitizer.truncate(trimmed, limit: Self.maxProfileChars)
        )

        lock.lock()
        defer { lock.unlock() }
        profiles[bundleID] = sanitized
        touch(bundleID)
        persist()
    }

    func clear(forApp bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard cache[bundleID] != nil || profiles[bundleID] != nil else { return }
        cache[bundleID] = nil
        profiles[bundleID] = nil
        pendingCounts[bundleID] = nil
        appOrder.removeAll { $0 == bundleID }
        persist()
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        guard !cache.isEmpty || !profiles.isEmpty else { return }
        cache = [:]
        profiles = [:]
        pendingCounts = [:]
        appOrder = []
        persist()
    }

    /// Moves `bundleID` to the most-recently-touched end of `appOrder` and evicts the
    /// oldest-touched app (exemplars, profile, and pending count) once `maxApps` is exceeded.
    /// Caller must hold `lock`.
    private func touch(_ bundleID: String) {
        appOrder.removeAll { $0 == bundleID }
        appOrder.append(bundleID)
        while appOrder.count > Self.maxApps {
            let evicted = appOrder.removeFirst()
            cache[evicted] = nil
            profiles[evicted] = nil
            pendingCounts[evicted] = nil
        }
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
                return Self.migratingLegacyKeys(state)
            }
            // Back-compat: pre-L1 files stored the raw `[String: [String]]` map with no order.
            let legacyEntries = try JSONDecoder().decode([String: [String]].self, from: plaintext)
            return Self.migratingLegacyKeys(PersistedState(order: Array(legacyEntries.keys), entries: legacyEntries))
        } catch {
            logger.error("Failed to decrypt per-app style memory, starting fresh: \(error, privacy: .public)")
            return empty
        }
    }

    /// Back-compat for the `web:`/`app:` key namespacing (see `StyleContextKeyResolver`):
    /// entries persisted before that change are keyed by a bare bundle id (no prefix). Rewrites
    /// any such key to `"app:<bundleID>"` on load so old per-app profiles stay reachable under
    /// the new scheme instead of silently becoming orphaned dead entries. A key that already
    /// carries a `web:`/`app:` prefix is left untouched. Two legacy bare keys can't collide
    /// after prefixing (they were already unique bundle ids), so this is a pure rename, not a
    /// merge.
    private static func migratingLegacyKeys(_ state: PersistedState) -> PersistedState {
        func migrate(_ key: String) -> String {
            (key.hasPrefix(StyleContextKeyResolver.webPrefix) || key.hasPrefix(StyleContextKeyResolver.appPrefix))
                ? key
                : StyleContextKeyResolver.appPrefix + key
        }
        guard state.order.contains(where: { !$0.hasPrefix(StyleContextKeyResolver.webPrefix) && !$0.hasPrefix(StyleContextKeyResolver.appPrefix) })
            || state.entries.keys.contains(where: { !$0.hasPrefix(StyleContextKeyResolver.webPrefix) && !$0.hasPrefix(StyleContextKeyResolver.appPrefix) })
        else {
            return state
        }
        return PersistedState(
            order: state.order.map(migrate),
            entries: Dictionary(uniqueKeysWithValues: state.entries.map { (migrate($0.key), $0.value) }),
            profiles: Dictionary(uniqueKeysWithValues: state.profiles.map { (migrate($0.key), $0.value) }),
            pendingSinceConsolidation: Dictionary(uniqueKeysWithValues: state.pendingSinceConsolidation.map { (migrate($0.key), $0.value) })
        )
    }

    private func persist() {
        guard let storeURL else { return }
        guard let key = existingKey() ?? generateAndStoreKey() else {
            logger.error("No encryption key available; not persisting per-app style memory")
            return
        }
        do {
            let plaintext = try JSONEncoder().encode(
                PersistedState(order: appOrder, entries: cache, profiles: profiles, pendingSinceConsolidation: pendingCounts)
            )
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
