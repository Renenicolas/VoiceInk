import Foundation
import FoundationModels

// voiceink-fm-cleanup — dictation transcript cleanup via the Apple Intelligence
// on-device foundation model, shaped to VoiceInk's `localCLI` provider contract:
// prompts arrive in VOICEINK_SYSTEM_PROMPT / VOICEINK_USER_PROMPT env vars and the
// cleaned text is written to stdout.
//
// Fail-safe: on ANY problem (Apple Intelligence off, guardrail refusal, timeout…)
// the raw transcript is printed unchanged and we exit 0, so dictation always
// delivers something. Diagnostics go to stderr only.
//
// Build: swiftc -O -parse-as-library fm-cleanup.swift -o voiceink-fm-cleanup

@main
struct FMCleanup {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        let system = env["VOICEINK_SYSTEM_PROMPT"] ?? ""
        let user = env["VOICEINK_USER_PROMPT"] ?? ""

        guard !user.isEmpty else {
            FileHandle.standardError.write(Data("fm-cleanup: VOICEINK_USER_PROMPT is empty\n".utf8))
            exit(64)
        }

        // The raw transcript, for fallback output. VoiceInk wraps it as
        // "\n<USER_MESSAGE>\n{text}\n</USER_MESSAGE>".
        let rawTranscript = extractUserMessage(from: user)

        func fallback(_ reason: String) -> Never {
            FileHandle.standardError.write(Data("fm-cleanup fallback: \(reason)\n".utf8))
            print(rawTranscript)
            exit(0)
        }

        // Without cleanup instructions the model would chat with the transcript
        // instead of rewriting it — raw text is safer than a chatbot reply.
        guard !system.isEmpty else {
            fallback("empty-system-prompt")
        }

        // permissiveContentTransformations is Apple's sanctioned guardrail mode for
        // rewriting user-provided content (avoids most spurious refusals).
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard case .available = model.availability else {
            fallback("apple-intelligence-unavailable: \(model.availability)")
        }

        let session = LanguageModelSession(model: model, instructions: system)
        do {
            let response = try await session.respond(
                to: user,
                options: GenerationOptions(temperature: 0.2)
            )
            let cleaned = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { fallback("empty-response") }
            print(cleaned)
        } catch {
            fallback("generation-failed: \(error)")
        }
    }

    static func extractUserMessage(from wrapped: String) -> String {
        if let start = wrapped.range(of: "<USER_MESSAGE>"),
           let end = wrapped.range(of: "</USER_MESSAGE>", range: start.upperBound..<wrapped.endIndex) {
            return String(wrapped[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return wrapped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
