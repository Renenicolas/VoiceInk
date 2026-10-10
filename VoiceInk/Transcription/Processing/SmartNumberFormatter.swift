import Foundation

/// Turns spoken numbers into the way Rene would type them.
///
///   "one hundred twenty-five thousand dollars" -> "$125,000"
///   "eight hundred bucks"                      -> "$800"
///   "it costs one fifty"                       -> "it costs $150"
///   "at eight thirty"                          -> "at 8:30"
///   "fifteen million"                          -> "15 million"
///   "one hundred and ninety K"                 -> "190K"
///   "twenty percent"                           -> "20%"
///   "10 grand"                                 -> "$10,000"
///
/// Deliberately conservative: a lone number word ("one of them", "six eight short clips")
/// is left alone unless a unit like dollars/percent/K follows it. Rules only, no AI, so it adds
/// no delay and can't invent words.
enum SmartNumberFormatter {
    static let defaultsKey = "SmartNumberFormatting"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    // MARK: - Vocabulary

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9,
    ]
    private static let teens: [String: Int] = [
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    private static var allNumberWords: [String] {
        Array(units.keys) + Array(teens.keys) + Array(tens.keys) + ["hundred"] + Array(scales.keys)
    }

    private static let moneyCues: Set<String> = [
        "cost", "costs", "costed", "price", "priced", "pay", "paid", "paying", "pays",
        "spent", "spend", "spending", "charge", "charged", "charges", "for", "is", "was", "be",
        "about", "around", "like", "just", "only", "under", "over",
    ]
    private static let strongMoneyCues: Set<String> = [
        "cost", "costs", "costed", "price", "priced", "pay", "paid", "paying", "pays",
        "spent", "spend", "spending", "charge", "charged", "charges", "bucks", "dollars",
    ]

    // MARK: - Entry point

    static func format(_ text: String) -> String {
        guard isEnabled, !text.isEmpty else { return text }
        var out = convertSpelledNumbers(in: text)
        out = applyUnitRules(to: out)
        return out
    }

    // MARK: - Spelled numbers -> digits

    private struct Piece {
        var words: [String]   // original words (with original casing), "and"/hyphens dropped
        var value: Int
    }

    private static func convertSpelledNumbers(in text: String) -> String {
        let alternation = allNumberWords.sorted { $0.count > $1.count }.joined(separator: "|")
        let word = "(?:\(alternation))"
        let pattern = "\\b\(word)(?:(?:\\s+and\\s+|[\\s-]+)\(word))*\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = match.range
            result += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            let phrase = ns.substring(with: r)
            let before = ns.substring(to: r.location)
            let after = ns.substring(from: r.location + r.length)
            result += rewrite(phrase: phrase, before: before, after: after)
            cursor = r.location + r.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    /// Rewrites one run of number words. Falls back to the original text for anything unclear.
    private static func rewrite(phrase: String, before: String, after: String) -> String {
        let rawWords = phrase.components(separatedBy: CharacterSet(charactersIn: " -\t\n"))
            .filter { !$0.isEmpty }
        let words = rawWords.filter { $0.lowercased() != "and" }
        let lower = words.map { $0.lowercased() }
        let prevWord = lastWord(of: before)
        let nextWord = firstWord(of: after)

        // Colloquial pairs first: "one fifty" (price) or "eight thirty" (time).
        if lower.count == 2,
           let h = units[lower[0]] ?? teens[lower[0]],
           h > 0,
           let m = tens[lower[1]] ?? teens[lower[1]] {
            if prevWord == "at" || ["am", "pm", "a.m.", "p.m."].contains(nextWord), h <= 12 {
                return "\(h):\(String(format: "%02d", m))"
            }
            if let p = prevWord, strongMoneyCues.contains(p) || (moneyCues.contains(p) && isMoneyish(before)) {
                return "$\(h * 100 + m)"
            }
            return phrase
        }

        guard let pieces = parse(lower, original: words) else { return phrase }

        var parts: [String] = []
        for (i, piece) in pieces.enumerated() {
            let isLast = i == pieces.count - 1
            let followedByUnit = isLast && isUnitWord(nextWord)
            // Lone single words stay words ("one of them"), unless a unit follows.
            if piece.words.count == 1 && !followedByUnit && !isScaleOnly(piece) {
                parts.append(piece.words[0])
                continue
            }
            parts.append(render(piece))
        }
        return parts.joined(separator: " ")
    }

    /// Strict number grammar. Splits into several numbers where the words can't be one number,
    /// e.g. "fifty three hundred" -> 53, 100? No: returns nil for anything ambiguous instead.
    private static func parse(_ lower: [String], original: [String]) -> [Piece]? {
        var pieces: [Piece] = []
        var total = 0
        var current = 0
        var lastKind = ""   // "unit", "teen", "tens", "hundred", "scale"
        var words: [String] = []

        func flush() {
            if !words.isEmpty { pieces.append(Piece(words: words, value: total + current)) }
            total = 0; current = 0; lastKind = ""; words = []
        }

        for (i, w) in lower.enumerated() {
            let orig = original[i]
            if let u = units[w] {
                if lastKind == "" || lastKind == "tens" || lastKind == "hundred" || lastKind == "scale" {
                    current += u
                } else {
                    // "six eight": two separate numbers; ambiguous, keep as words.
                    return nil
                }
                lastKind = "unit"
            } else if let t = teens[w] {
                if lastKind == "" || lastKind == "hundred" || lastKind == "scale" {
                    current += t
                } else { return nil }
                lastKind = "teen"
            } else if let t = tens[w] {
                if lastKind == "" || lastKind == "hundred" || lastKind == "scale" {
                    current += t
                } else { return nil }
                lastKind = "tens"
            } else if w == "hundred" {
                if current == 0 { current = 1 }
                guard current < 100 else { return nil }
                current *= 100
                lastKind = "hundred"
            } else if let s = scales[w] {
                if current == 0 && total == 0 { current = 1 }
                guard current > 0 else { return nil }
                total += current * s
                current = 0
                lastKind = "scale"
            } else {
                return nil
            }
            words.append(orig)
        }
        flush()
        return pieces
    }

    private static func render(_ piece: Piece) -> String {
        let lower = piece.words.map { $0.lowercased() }
        // "fifteen million" / "two point" style: keep the big scale word readable.
        if let last = lower.last, last == "million" || last == "billion",
           let scale = scales[last], piece.value % scale == 0 {
            return "\(piece.value / scale) \(last)"
        }
        return grouped(piece.value)
    }

    private static func isScaleOnly(_ piece: Piece) -> Bool { false }

    // MARK: - Units: dollars, bucks, grand, percent, K

    private static func applyUnitRules(to text: String) -> String {
        var s = text
        // 125,000 dollars / 800 bucks -> $125,000 / $800
        s = replace(s, #"(?<![\$\d])(\d[\d,]*(?:\.\d+)?)\s+(?:dollars|bucks)\b"#, with: "\\$$1")
        // 10 grand -> $10,000
        s = replaceGrand(s)
        // 20 percent -> 20%
        s = replace(s, #"\b(\d+(?:\.\d+)?)\s+percent\b"#, with: "$1%")
        // 190 K -> 190K
        s = replace(s, #"\b(\d+(?:\.\d+)?)\s+[kK]\b"#, with: "$1K")
        return s
    }

    private static func replaceGrand(_ text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: #"(?<![\$\d])(\d+)\s+grand\b"#, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let n = Int(ns.substring(with: m.range(at: 1))) ?? 0
            out += "$" + grouped(n * 1000)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Helpers

    private static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    private static func grouped(_ n: Int) -> String {
        guard n >= 10_000 else { return String(n) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    private static func isUnitWord(_ w: String?) -> Bool {
        guard let w else { return false }
        return ["dollars", "bucks", "percent", "k", "grand", "thousand", "million", "billion"].contains(w)
    }

    private static func isMoneyish(_ before: String) -> Bool {
        let tail = before.lowercased().suffix(60)
        return strongMoneyCues.contains { tail.contains($0) } || tail.contains("$")
    }

    private static func lastWord(of s: String) -> String? {
        s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "." && $0 != "'" }).last.map(String.init)
    }

    private static func firstWord(of s: String) -> String? {
        s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "." }).first.map(String.init)
    }
}
