import Foundation

struct AIEnhancementOutputFilter {
    static func filter(_ text: String) -> String {
        var processedText = text
        let patterns = [
            #"(?s)<thinking>(.*?)</thinking>"#,
            #"(?s)<think>(.*?)</think>"#,
            #"(?s)<reasoning>(.*?)</reasoning>"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(processedText.startIndex..., in: processedText)
                processedText = regex.stringByReplacingMatches(in: processedText, options: [], range: range, withTemplate: "")
            }
        }

        // PromptTagSanitizer inserts zero-width spaces (U+200B) into the transcript/context
        // before it reaches the model. In clean/rewrite/enhance modes the model largely echoes
        // its input, so those invisible characters can survive into the pasted result and
        // silently corrupt copied code/text. Strip them from the final output; they only ever
        // existed as an input-side defense, never as intentional content.
        processedText = processedText.replacingOccurrences(of: "\u{200B}", with: "")

        return processedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
} 