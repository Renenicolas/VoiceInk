import Foundation
import os

/// Kicks off background re-distillation of an app's per-app voice profile once
/// `PerAppStyleMemory.record` reports its consolidation threshold was hit.
///
/// OFF THE DICTATION HOT PATH: `consolidateInBackground` returns immediately — it only takes
/// a lock and starts a detached `Task`; the actual (slow, ~seconds, CLI-shelling-out) call
/// happens on that task, never on the caller's. Throttled to one in-flight consolidation per
/// app so a burst of dictations in the same app can't pile up overlapping CLI calls. Fails
/// silently: any error (CLI missing, timeout, empty output) is logged and dropped — the app
/// keeps whatever profile it had before.
final class PerAppVoiceProfileConsolidator {
    static let shared = PerAppVoiceProfileConsolidator()

    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "PerAppVoiceProfileConsolidator")
    private let lock = NSLock()
    private var inFlightApps: Set<String> = []

    private init() {}

    func consolidateInBackground(forApp bundleID: String) {
        lock.lock()
        guard !inFlightApps.contains(bundleID) else {
            lock.unlock()
            return
        }
        inFlightApps.insert(bundleID)
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            defer { self?.finish(bundleID) }

            let exemplars = PerAppStyleMemory.shared.recentExemplars(forApp: bundleID)
            guard !exemplars.isEmpty else { return }
            let existingProfile = PerAppStyleMemory.shared.profile(forApp: bundleID)
            let material = Self.buildMaterial(existingProfile: existingProfile, exemplars: exemplars)

            do {
                let profile = try await PerAppVoiceProfileService.distill(material: material)
                guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                PerAppStyleMemory.shared.setProfile(profile, forApp: bundleID)
            } catch {
                self?.logger.error("Style profile consolidation failed, keeping last profile: \(error.localizedDescription, privacy: .private)")
            }
        }
    }

    private func finish(_ bundleID: String) {
        lock.lock()
        inFlightApps.remove(bundleID)
        lock.unlock()
    }

    private static func buildMaterial(existingProfile: String?, exemplars: [String]) -> String {
        var parts: [String] = []
        if let existingProfile, !existingProfile.isEmpty {
            parts.append("Current profile (refine, don't just repeat it):\n\(existingProfile)")
        }
        let examples = exemplars.enumerated()
            .map { "Example \($0.offset + 1):\n\($0.element)" }
            .joined(separator: "\n\n")
        parts.append("Recent writing examples from this app:\n\(examples)")
        return parts.joined(separator: "\n\n")
    }
}
