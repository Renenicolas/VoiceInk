import Foundation

/// Shared helpers for safely building the CLI prompt envelope out of untrusted text
/// (screen OCR, clipboard, selected text, dictation transcript). Reused everywhere that
/// text gets interpolated into a `<TAG>...</TAG>` block before being handed to a CLI.
enum PromptTagSanitizer {
    /// Matches the Windows twin's `MAX_CONTEXT_CHARS` (src/shared/prompts.ts) — keep in sync.
    static let maxContextChars = 4000

    /// Neutralizes tag-like and markdown-header-like sequences inside untrusted text so it
    /// can't break out of the tag it's interpolated into, open a *new* fake tag (e.g. an
    /// injected `<SYSTEM_MESSAGE>`), or impersonate one of the envelope's own `# System
    /// Message` / `# User Message Payload` section headers. Inserts a zero-width space right
    /// after every "<" and right after every line-leading "#", which render as inert text.
    /// Idempotent: a `<` or line-leading `#` already followed by U+200B is skipped, so a
    /// second pass is a no-op.
    static func sanitize(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: "<(?!\u{200B})",
            with: "<\u{200B}",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "(?m)^([ \\t]*)#(?!\u{200B})",
            with: "$1#\u{200B}",
            options: .regularExpression
        )
        return result
    }

    /// Caps an untrusted context block so one oversized block can't blow up the injection
    /// payload surface, latency/cost, or (since the full prompt can be passed as an argv
    /// positional) ARG_MAX.
    static func truncate(_ text: String, limit: Int = maxContextChars) -> String {
        guard text.count > limit else { return text }
        return "\(text.prefix(limit))\n[…truncated, \(text.count - limit) more characters]"
    }
}
