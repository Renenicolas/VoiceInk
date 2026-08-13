import Foundation

/// Turns the onboarding sweep's voice manifests into starting per-app/per-site voice
/// profiles — the step that kills the cold start, so a new user's Gmail voice and notes
/// voice already exist on day one instead of after three weeks of dictation.
///
/// A manifest (`os/sweep/voice/<lane>.json`, written by `scripts/sweep.mjs run`) is a
/// LIST OF PATHS plus the profile key the person consented to file them under. It
/// deliberately contains none of their writing: the sweep points at the files, and this
/// side reads them. One copy of a person's prose, in the place they already keep it.
///
/// EVERY RULE THE SWEEP ENFORCES IS RE-ENFORCED HERE. The sweep is a different program in
/// a different language that a user can hand-edit; an importer that trusts its input is
/// one bad JSON file away from distilling someone's medical history. `subject: "self"` is
/// refused outright, unreadable keys are refused, and only plain-text prose is opened.
///
/// LOCAL ONLY, like every other path into `PerAppStyleMemory`: distillation goes through
/// `PerAppVoiceProfileService.distill`, which is hard-wired to the tools-off `claude` CLI.
enum SweepVoiceImport {
    struct Manifest: Decodable, Identifiable, Equatable {
        let lane: String
        let profileKey: String
        let subject: String
        let fileCount: Int
        let files: [String]

        var id: String { lane }

        /// True when the writing came off plain disk, which carries no app of origin — the
        /// person picks the app at import time. Connector lanes (Gmail, Slack, Notion)
        /// already know theirs.
        var needsAppAssignment: Bool { profileKey == "default" }
    }

    enum ImportError: LocalizedError, Equatable {
        case ownersOwnRecords(lane: String)
        case unusableProfileKey(String)
        case noReadableWriting(lane: String)
        case emptyProfile

        var errorDescription: String? {
            switch self {
            case .ownersOwnRecords(let lane):
                return "Lane “\(lane)” holds your own private records. Those never teach a voice profile."
            case .unusableProfileKey(let key):
                return "“\(key)” isn’t a profile key this app can write to."
            case .noReadableWriting(let lane):
                return "Lane “\(lane)” had no readable plain-text writing in it."
            case .emptyProfile:
                return "The local model returned an empty profile."
            }
        }
    }

    /// Matches `PerAppVoiceProfileService.maxMaterialChars` — distill truncates anyway, but
    /// stopping at the read means not pulling a hundred megabytes of notes into memory to
    /// throw 99% of it away.
    static let maxMaterialChars = 8000

    /// Plain text only. The sweep's census also counts .pdf/.docx/.pages as writing because
    /// it's judging whether a folder is worth reading at all, but this side has to actually
    /// parse the bytes, and a PDF read as UTF-8 is garbage that would poison the profile.
    static let readableExtensions: Set<String> = ["md", "txt", "text", "org", "tex", "markdown"]

    // MARK: - Reading manifests

    /// Every usable manifest in a sweep's voice folder. Unreadable or malformed files are
    /// skipped rather than failing the whole import — one bad lane shouldn't cost the user
    /// the other eleven.
    static func manifests(in directory: URL) -> [Manifest] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url -> Manifest? in
                guard let data = try? Data(contentsOf: url),
                      let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
                // Refused at the door, not at apply time, so it never appears in a list the
                // user can click.
                guard manifest.subject != "self" else { return nil }
                guard manifest.fileCount > 0 else { return nil }
                return manifest
            }
            .sorted { $0.lane < $1.lane }
    }

    /// The key this manifest writes to, or nil when the person still has to choose an app.
    /// Validates the shape rather than trusting it: only the two namespaces
    /// `StyleContextKeyResolver` produces are writable, so an imported profile can never
    /// land somewhere dictation will never look for it.
    static func storageKey(for manifest: Manifest) -> String? {
        guard !manifest.needsAppAssignment else { return nil }
        return isWritableKey(manifest.profileKey) ? manifest.profileKey : nil
    }

    static func isWritableKey(_ key: String) -> Bool {
        let prefixes = [StyleContextKeyResolver.appPrefix, StyleContextKeyResolver.webPrefix]
        guard let prefix = prefixes.first(where: { key.hasPrefix($0) }) else { return false }
        return key.count > prefix.count
    }

    // MARK: - Reading the writing itself

    /// Concatenates the manifest's prose, capped. Files that don't exist, aren't plain text,
    /// or can't be decoded are skipped — a manifest is a snapshot of a disk that has kept
    /// changing since the sweep ran.
    static func material(for manifest: Manifest) throws -> String {
        guard manifest.subject != "self" else { throw ImportError.ownersOwnRecords(lane: manifest.lane) }

        var chunks: [String] = []
        var total = 0
        for path in manifest.files {
            if total >= maxMaterialChars { break }
            let url = URL(fileURLWithPath: path)
            guard readableExtensions.contains(url.pathExtension.lowercased()),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let room = maxMaterialChars - total
            chunks.append(trimmed.count > room ? String(trimmed.prefix(room)) : trimmed)
            total += min(trimmed.count, room)
        }

        guard !chunks.isEmpty else { throw ImportError.noReadableWriting(lane: manifest.lane) }
        return chunks.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Applying

    /// Distills and stores. `key` is passed explicitly rather than read off the manifest so
    /// the caller must have resolved the "default" case (by asking the user for an app)
    /// before anything is written.
    @discardableResult
    static func apply(_ manifest: Manifest, to key: String) async throws -> String {
        guard manifest.subject != "self" else { throw ImportError.ownersOwnRecords(lane: manifest.lane) }
        guard isWritableKey(key) else { throw ImportError.unusableProfileKey(key) }

        let profile = try await PerAppVoiceProfileService.distill(material: try material(for: manifest))
        guard !profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.emptyProfile }

        PerAppStyleMemory.shared.setProfile(profile, forApp: key)
        return profile
    }
}
