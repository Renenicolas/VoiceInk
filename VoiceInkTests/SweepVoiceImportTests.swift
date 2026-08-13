import Foundation
import Testing
@testable import VoiceInk

/// Covers the pure half of `SweepVoiceImport` — everything except `apply`, which shells out
/// to the local `claude` CLI. These are the rules that turn a privacy promise into a lie if
/// they silently break, so each one gets its own assertion: the importer must not trust the
/// sweep's output, because a manifest is a plain JSON file on disk that anyone can edit.
struct SweepVoiceImportTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeManifest(
        _ dir: URL,
        lane: String,
        profileKey: String,
        subject: String = "work",
        files: [String]
    ) throws {
        let json: [String: Any] = [
            "lane": lane,
            "profileKey": profileKey,
            "subject": subject,
            "fileCount": files.count,
            "files": files,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: dir.appendingPathComponent("\(lane).json"))
    }

    private func writeSample(_ dir: URL, _ name: String, _ body: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - Refusing what it must refuse

    @Test func refusesTheOwnersOwnPrivateRecords() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = try writeSample(dir, "note.md", "I write in short declarative sentences.")
        try writeManifest(dir, lane: "medical", profileKey: "app:com.apple.mail", subject: "self", files: [sample])

        // Never even offered to the user.
        #expect(SweepVoiceImport.manifests(in: dir).isEmpty)

        // And refused at the read, so a hand-built Manifest can't route around the listing.
        let manifest = SweepVoiceImport.Manifest(
            lane: "medical", profileKey: "app:com.apple.mail", subject: "self", fileCount: 1, files: [sample]
        )
        #expect(throws: SweepVoiceImport.ImportError.ownersOwnRecords(lane: "medical")) {
            _ = try SweepVoiceImport.material(for: manifest)
        }
    }

    @Test func onlyTheTwoKeyNamespacesDictationLooksUpAreWritable() {
        #expect(SweepVoiceImport.isWritableKey("app:com.tinyspeck.slackmacgap"))
        #expect(SweepVoiceImport.isWritableKey("web:mail.google.com"))
        // A profile filed under any of these would be stored where nothing ever reads it.
        #expect(!SweepVoiceImport.isWritableKey("default"))
        #expect(!SweepVoiceImport.isWritableKey("app:"))
        #expect(!SweepVoiceImport.isWritableKey("web:"))
        #expect(!SweepVoiceImport.isWritableKey("com.apple.mail"))
        #expect(!SweepVoiceImport.isWritableKey(""))
    }

    @Test func diskWritingHasNoAppOfOriginAndMustBeAssignedOne() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = try writeSample(dir, "note.md", "Some prose.")
        try writeManifest(dir, lane: "personal", profileKey: "default", files: [sample])

        let manifest = try #require(SweepVoiceImport.manifests(in: dir).first)
        #expect(manifest.needsAppAssignment)
        #expect(SweepVoiceImport.storageKey(for: manifest) == nil, "must not silently pick an app")
    }

    @Test func connectorWritingKnowsItsOwnKey() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = try writeSample(dir, "note.md", "Some prose.")
        try writeManifest(dir, lane: "gmail", profileKey: "web:mail.google.com", files: [sample])

        let manifest = try #require(SweepVoiceImport.manifests(in: dir).first)
        #expect(!manifest.needsAppAssignment)
        #expect(SweepVoiceImport.storageKey(for: manifest) == "web:mail.google.com")
    }

    // MARK: - Reading the writing

    @Test func readsOnlyPlainTextProse() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let md = try writeSample(dir, "letter.md", "Hi there — quick one.")
        // The sweep's census counts PDFs as writing (it's sizing a folder, not parsing it);
        // read as UTF-8 they are garbage that would poison the distilled profile.
        let pdf = try writeSample(dir, "scan.pdf", "%PDF-1.4 binary-ish garbage")
        let missing = dir.appendingPathComponent("deleted-since-the-sweep.md").path
        let manifest = SweepVoiceImport.Manifest(
            lane: "notes", profileKey: "app:com.apple.mail", subject: "work", fileCount: 3, files: [md, pdf, missing]
        )

        let material = try SweepVoiceImport.material(for: manifest)
        #expect(material.contains("Hi there"))
        #expect(!material.contains("%PDF"), "non-prose must never reach the distiller")
    }

    @Test func materialIsCappedNoMatterHowMuchWritingExists() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var files: [String] = []
        for i in 0..<40 {
            files.append(try writeSample(dir, "n\(i).md", String(repeating: "word ", count: 1000)))
        }
        let manifest = SweepVoiceImport.Manifest(
            lane: "big", profileKey: "app:com.apple.mail", subject: "work", fileCount: files.count, files: files
        )

        let material = try SweepVoiceImport.material(for: manifest)
        #expect(material.count <= SweepVoiceImport.maxMaterialChars + 64, "cap applies at the read, not just at distill")
    }

    @Test func aLaneWithNothingReadableFailsRatherThanDistillingEmptiness() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let empty = try writeSample(dir, "blank.md", "   \n\n  ")
        let manifest = SweepVoiceImport.Manifest(
            lane: "hollow", profileKey: "app:com.apple.mail", subject: "work", fileCount: 1, files: [empty]
        )
        #expect(throws: SweepVoiceImport.ImportError.noReadableWriting(lane: "hollow")) {
            _ = try SweepVoiceImport.material(for: manifest)
        }
    }

    @Test func oneUnreadableManifestDoesNotCostTheUserTheOthers() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sample = try writeSample(dir, "note.md", "Prose.")
        try writeManifest(dir, lane: "good", profileKey: "web:notion.so", files: [sample])
        try "{ not json".write(to: dir.appendingPathComponent("broken.json"), atomically: true, encoding: .utf8)
        // A connector lane whose extraction hasn't run yet has no files to offer.
        try writeManifest(dir, lane: "pending", profileKey: "app:com.tinyspeck.slackmacgap", files: [])

        let manifests = SweepVoiceImport.manifests(in: dir)
        #expect(manifests.map(\.lane) == ["good"])
    }
}
