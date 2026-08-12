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
}
