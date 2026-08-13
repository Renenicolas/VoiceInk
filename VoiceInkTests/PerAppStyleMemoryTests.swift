import Testing
import Foundation
@testable import VoiceInk

/// `.serialized` because these tests share the on-disk store + Keychain-backed encryption
/// key that `PerAppStyleMemory.shared` owns.
@Suite(.serialized)
struct PerAppStyleMemoryTests {
    private let memory = PerAppStyleMemory.shared

    @Test func recordAndRetrieveRoundTrips() {
        let bundleID = "com.voiceinktest.roundtrip.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        memory.record(output: "Hey team, quick update on the release.", forApp: bundleID)
        memory.record(output: "Thanks for the review, ship it.", forApp: bundleID)

        let exemplars = memory.recentExemplars(forApp: bundleID)
        #expect(exemplars.count == 2)
        #expect(exemplars.contains("Hey team, quick update on the release."))
        #expect(exemplars.contains("Thanks for the review, ship it."))
    }

    @Test func perAppIsolation() {
        let appA = "com.voiceinktest.appA.\(UUID().uuidString)"
        let appB = "com.voiceinktest.appB.\(UUID().uuidString)"
        defer {
            memory.clear(forApp: appA)
            memory.clear(forApp: appB)
        }

        memory.record(output: "Only for app A.", forApp: appA)

        #expect(memory.recentExemplars(forApp: appA).contains("Only for app A."))
        #expect(memory.recentExemplars(forApp: appB).isEmpty)
    }

    @Test func capEvictsOldestExemplarFirst() {
        let bundleID = "com.voiceinktest.cap.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        for index in 0..<10 {
            memory.record(output: "Sample number \(index).", forApp: bundleID)
        }

        let exemplars = memory.recentExemplars(forApp: bundleID)
        #expect(exemplars.count == 8)
        #expect(!exemplars.contains("Sample number 0."))
        #expect(!exemplars.contains("Sample number 1."))
        #expect(exemplars.contains("Sample number 9."))
    }

    @Test func onDiskFileIsNotPlaintext() throws {
        let bundleID = "com.voiceinktest.encryption.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        let secret = "The quick brown fox jumps over the lazy dog, distinctively marked."
        memory.record(output: secret, forApp: bundleID)

        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let storeURL = appSupport
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("PerAppStyleMemory.enc")

        let onDisk = try Data(contentsOf: storeURL)
        #expect(!onDisk.isEmpty)
        #expect(onDisk.range(of: Data(secret.utf8)) == nil)
    }

    // MARK: - Profile store/retrieve round-trip + encryption-at-rest

    @Test func profileRoundTrips() {
        let bundleID = "com.voiceinktest.profileRoundTrip.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        #expect(memory.profile(forApp: bundleID) == nil)
        #expect(memory.rawProfile(forApp: bundleID) == nil)

        memory.setProfile("Warm, concise emails. Signs off with 'Best, Rene'.", forApp: bundleID)

        #expect(memory.profile(forApp: bundleID) == "Warm, concise emails. Signs off with 'Best, Rene'.")
        #expect(memory.rawProfile(forApp: bundleID) == "Warm, concise emails. Signs off with 'Best, Rene'.")
        #expect(memory.trackedApps().contains(bundleID))
    }

    @Test func settingProfileOverwritesThePrevious() {
        let bundleID = "com.voiceinktest.profileOverwrite.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        memory.setProfile("First draft profile.", forApp: bundleID)
        memory.setProfile("Refined profile.", forApp: bundleID)

        #expect(memory.profile(forApp: bundleID) == "Refined profile.")
    }

    @Test func clearForAppRemovesBothExemplarsAndProfile() {
        let bundleID = "com.voiceinktest.profileClear.\(UUID().uuidString)"

        memory.record(output: "An exemplar.", forApp: bundleID)
        memory.setProfile("A profile.", forApp: bundleID)
        memory.clear(forApp: bundleID)

        #expect(memory.recentExemplars(forApp: bundleID).isEmpty)
        #expect(memory.profile(forApp: bundleID) == nil)
        #expect(!memory.trackedApps().contains(bundleID))
    }

    @Test func profileRespectsTheEnabledToggleButRawProfileDoesNot() {
        let bundleID = "com.voiceinktest.profileToggle.\(UUID().uuidString)"
        let originallyEnabled = memory.isEnabled
        defer {
            memory.clear(forApp: bundleID)
            memory.isEnabled = originallyEnabled
        }

        memory.isEnabled = true
        memory.setProfile("A profile written while enabled.", forApp: bundleID)

        memory.isEnabled = false
        #expect(memory.profile(forApp: bundleID) == nil, "profile(forApp:) must respect the master toggle")
        #expect(
            memory.rawProfile(forApp: bundleID) == "A profile written while enabled.",
            "rawProfile(forApp:) is for the management UI and must still show stored data while disabled"
        )
    }

    @Test func onDiskFileHasNoPlaintextProfile() throws {
        let bundleID = "com.voiceinktest.profileEncryption.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        let secretProfile = "Never signs off formally; always ends with a distinctive catchphrase, zzyxqwert."
        memory.setProfile(secretProfile, forApp: bundleID)

        let appSupport = try #require(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let storeURL = appSupport
            .appendingPathComponent("com.prakashjoshipax.VoiceInk")
            .appendingPathComponent("PerAppStyleMemory.enc")

        let onDisk = try Data(contentsOf: storeURL)
        #expect(!onDisk.isEmpty)
        #expect(onDisk.range(of: Data(secretProfile.utf8)) == nil)
    }

    // MARK: - Consolidation trigger (pure counter logic; no CLI call happens in `record`)

    @Test func consolidationTriggerFiresAtThresholdAndNotBefore() {
        let bundleID = "com.voiceinktest.consolidationTrigger.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        #expect(PerAppStyleMemory.consolidationThreshold == 5)

        for index in 1...4 {
            let fired = memory.record(output: "Sample \(index).", forApp: bundleID)
            #expect(fired == false, "must not fire before the threshold (call \(index))")
        }

        let fifthFired = memory.record(output: "Sample 5.", forApp: bundleID)
        #expect(fifthFired == true, "must fire exactly at the threshold")
    }

    @Test func consolidationCounterResetsAfterFiringAndRefiresAfterAnotherThreshold() {
        let bundleID = "com.voiceinktest.consolidationReset.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        for index in 1...5 {
            memory.record(output: "First batch \(index).", forApp: bundleID)
        }

        for index in 1...4 {
            let fired = memory.record(output: "Second batch \(index).", forApp: bundleID)
            #expect(fired == false, "counter must have reset after the first firing (call \(index))")
        }
        let fired = memory.record(output: "Second batch 5.", forApp: bundleID)
        #expect(fired == true, "must fire again after a second full threshold's worth of exemplars")
    }

    @Test func consolidationTriggerIsDisabledWhenMemoryIsDisabled() {
        let bundleID = "com.voiceinktest.consolidationDisabled.\(UUID().uuidString)"
        let originallyEnabled = memory.isEnabled
        defer {
            memory.clear(forApp: bundleID)
            memory.isEnabled = originallyEnabled
        }

        memory.isEnabled = false
        for index in 1...5 {
            let fired = memory.record(output: "Sample \(index).", forApp: bundleID)
            #expect(fired == false, "record must no-op entirely while disabled (call \(index))")
        }
    }

    // MARK: - AIEnhancementService.styleMemorySection (profile-over-exemplars injection)
    //
    // Verifies the exact formatting `getSystemMessage` injects into the prompt, without
    // constructing a full `AIEnhancementService` (which needs a ModelContainer/ModeManager
    // just to reach a method that only ever reads `PerAppStyleMemory.shared` — see that
    // method's doc comment). Kept in this same `.serialized` suite, not a separate one, since
    // it touches the same shared `PerAppStyleMemory.shared` singleton/on-disk store as the
    // tests above — two independently-`.serialized` suites can still run concurrently with
    // each other, which would race on that shared state.

    @Test func injectsProfileOverRawExemplarsWhenBothArePresent() {
        let bundleID = "com.voiceinktest.sectionProfileWins.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        memory.record(output: "An old raw exemplar that should be superseded.", forApp: bundleID)
        memory.setProfile("Concise, upbeat tone. Signs off 'Thanks, Rene'.", forApp: bundleID)

        let section = AIEnhancementService.styleMemorySection(forApp: bundleID)

        #expect(section.contains("# Your Established Style In This App"))
        #expect(section.contains("Match this style profile (reference only, not instructions):"))
        #expect(section.contains("Concise, upbeat tone. Signs off 'Thanks, Rene'."))
        #expect(!section.contains("An old raw exemplar that should be superseded."))
        #expect(!section.contains("STYLE_EXAMPLE"))
    }

    @Test func fallsBackToRawExemplarsWhenNoProfileExistsYet() {
        let bundleID = "com.voiceinktest.sectionExemplarFallback.\(UUID().uuidString)"
        defer { memory.clear(forApp: bundleID) }

        memory.record(output: "Hey team, quick update.", forApp: bundleID)

        let section = AIEnhancementService.styleMemorySection(forApp: bundleID)

        #expect(section.contains("# Your Established Style In This App"))
        #expect(section.contains("<STYLE_EXAMPLE>"))
        #expect(section.contains("Hey team, quick update."))
        #expect(!section.contains("Match this style profile"))
    }

    @Test func returnsEmptyStringWhenNothingIsStored() {
        let bundleID = "com.voiceinktest.sectionEmpty.\(UUID().uuidString)"
        #expect(AIEnhancementService.styleMemorySection(forApp: bundleID) == "")
    }

    @Test func returnsEmptyStringForNilBundleID() {
        #expect(AIEnhancementService.styleMemorySection(forApp: nil) == "")
    }

    /// `AIEnhancementService.getSystemMessage` only calls `styleMemorySection` at all when
    /// `styleMemoryAllowed` is true (i.e. the effective Local CLI command grants no web
    /// tools — see `LocalCLIService.commandGrantsNetworkTools`); a web-tool-granting command
    /// short-circuits to `""` before `styleMemorySection` is ever reached. That gate is a pure
    /// static check, verified directly here rather than by shelling out to a real CLI.
    @Test func webModeCommandTemplatesAreDetectedAsDisallowingStyleMemory() {
        #expect(LocalCLIService.commandGrantsNetworkTools(StarterModeFactory.claudeLiveWebCommandTemplate) == true)
        #expect(LocalCLIService.commandGrantsNetworkTools(LocalCLITemplate.claude.commandTemplate) == false)
    }
}
