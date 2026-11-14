import Foundation

/// Minimal, literal cleanup of raw speech text. It only removes things, apart from two
/// spoken commands; it never rewrites:
/// - fillers (um, uh, er, hmm and their spellings),
/// - stutter repeats of 1 to 3 words ("the the", "I think I think"),
/// - "new line" and "new paragraph", which become line breaks.
/// When a removal leaves a sentence start, the next word gets the capital the removed word had.
///
/// Never touched: numbers, units, addresses and identifiers. A filler-shaped word right after a
/// number ("5 mm") or written in capitals ("ER") is a word, not a filler; repeats are only
/// collapsed for plain words (never "5 5", "foo.bar foo.bar"); and a capital is only moved onto a
/// plain lowercase word (never "iOS", "npm/x", "foo_bar").
public enum Cleanup {
    public static let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "hm", "mm", "mmm"]

    /// Doubled words that are usually meant ("very very", "had had"), never collapsed as 1-word repeats.
    public static let keepDoubled: Set<String> = [
        "very", "really", "so", "no", "yes", "yeah", "ha", "bye", "had", "that", "now", "too", "far", "many", "much", "more",
        "long", "again", "okay", "ok", "go", "hey", "is",
    ]

    public static func apply(_ text: String) -> String {
        var words = tokenize(text)
        words = applyCommands(words)
        words = removeFillers(words)
        words = collapseRepeats(words)
        return render(words)
    }

    // MARK: - Tokens

    /// A word with the punctuation stuck to it, or a line break.
    struct Word: Equatable {
        var lead = ""
        var core: String
        var trail = ""
        var isBreak = false
        var key: String { core.lowercased() }
        var endsSentence: Bool { trail.contains(where: { ".!?".contains($0) }) }
        var hasTrail: Bool { !trail.isEmpty }
        static func lineBreak(_ count: Int) -> Word { Word(core: String(repeating: "\n", count: count), isBreak: true) }
    }

    static func tokenize(_ text: String) -> [Word] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).flatMap { piece -> [Word] in
            // Keep existing line breaks as their own tokens.
            let parts = piece.split(separator: "\n", omittingEmptySubsequences: false)
            var out: [Word] = []
            for (i, part) in parts.enumerated() {
                if i > 0 { out.append(.lineBreak(1)) }
                if !part.isEmpty { out.append(split(String(part))) }
            }
            return out
        }
    }

    private static func split(_ s: String) -> Word {
        let chars = Array(s)
        var a = 0, b = chars.count
        while a < b, !chars[a].isLetter, !chars[a].isNumber { a += 1 }
        while b > a, !chars[b - 1].isLetter, !chars[b - 1].isNumber { b -= 1 }
        if a == b { return Word(core: s) }
        return Word(lead: String(chars[..<a]), core: String(chars[a..<b]), trail: String(chars[b...]))
    }

    static func render(_ words: [Word]) -> String {
        var out = ""
        for w in words {
            if w.isBreak {
                while out.hasSuffix(" ") { out.removeLast() }
                out += w.core
            } else {
                if !out.isEmpty, !out.hasSuffix("\n") { out += " " }
                out += w.lead + w.core + w.trail
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isCapitalised(_ w: Word) -> Bool { w.core.first?.isUppercase == true }

    private static func capitalise(_ w: inout Word) {
        // Only plain lowercase words: "iOS", "macOS", "npm.js" or "x_y" keep their spelling.
        guard let first = w.core.first, first.isLowercase, w.core.allSatisfy({ $0.isLetter && $0.isLowercase || $0 == "'" || $0 == "’" }),
            w.lead.isEmpty
        else { return }
        w.core = first.uppercased() + w.core.dropFirst()
    }

    /// True when position `i` starts a sentence or line.
    private static func atSentenceStart(_ words: [Word], _ i: Int) -> Bool {
        guard i > 0 else { return true }
        return words[i - 1].isBreak || words[i - 1].endsSentence
    }

    // MARK: - Commands

    private static let determiners: Set<String> = ["a", "the", "this", "that", "another", "one", "each", "every", "per", "my", "our", "your", "its", "their", "his", "her", "any", "no"]

    static func applyCommands(_ input: [Word]) -> [Word] {
        var words = input
        var i = 0
        while i + 1 < words.count {
            let first = words[i], second = words[i + 1]
            guard !first.isBreak, !second.isBreak, first.key == "new", second.key == "line" || second.key == "paragraph",
                first.trail.isEmpty
            else { i += 1; continue }
            let before = i > 0 ? words[i - 1] : nil
            let boundaryBefore = before == nil || before!.isBreak || before!.hasTrail
            let boundaryAfter = second.hasTrail || i + 2 == words.count
            let afterDeterminer = before.map { determiners.contains($0.key) && !$0.hasTrail } ?? false
            guard boundaryBefore || (boundaryAfter && !afterDeterminer) else { i += 1; continue }

            // Drop a trailing comma or other soft mark on the word before; keep . ? !
            if i > 0, !words[i - 1].isBreak, !words[i - 1].endsSentence {
                words[i - 1].trail = ""
            }
            let breaks = second.key == "paragraph" ? 2 : 1
            words.replaceSubrange(i...(i + 1), with: [.lineBreak(breaks)])
            // Merge with a break that is already there, and capitalise the next line.
            if i > 0, words[i - 1].isBreak {
                let total = min(2, words[i - 1].core.count + breaks)
                words.replaceSubrange((i - 1)...i, with: [.lineBreak(total)])
                i -= 1
            }
            if i + 1 < words.count, !words[i + 1].isBreak { capitalise(&words[i + 1]) }
            i += 1
        }
        return words
    }

    // MARK: - Fillers

    static func removeFillers(_ input: [Word]) -> [Word] {
        var words = input
        var i = 0
        while i < words.count {
            let w = words[i]
            guard !w.isBreak, fillers.contains(w.key), !isWordNotFiller(words, i) else { i += 1; continue }
            let wasStart = atSentenceStart(words, i)
            let capital = isCapitalised(w)
            // A filler that ends a sentence hands its . ? ! to the word before.
            if w.endsSentence, i > 0, !words[i - 1].isBreak, !words[i - 1].endsSentence {
                let mark = w.trail.filter { ".!?".contains($0) }
                words[i - 1].trail = String(words[i - 1].trail.filter { !",;:".contains($0) }) + mark
            }
            words.remove(at: i)
            if wasStart, capital, i < words.count, !words[i].isBreak { capitalise(&words[i]) }
        }
        return words
    }

    /// "5 mm", "ER", "HMM": shaped like a filler but a unit, an acronym or a shout.
    private static func isWordNotFiller(_ words: [Word], _ i: Int) -> Bool {
        let w = words[i]
        if w.core.count > 1, w.core.allSatisfy({ $0.isUppercase }) { return true }
        if !w.lead.isEmpty { return true }
        if i > 0, !words[i - 1].isBreak, words[i - 1].core.last?.isNumber == true, !words[i - 1].hasTrail { return true }
        return false
    }

    // MARK: - Repeats

    static func collapseRepeats(_ input: [Word]) -> [Word] {
        var words = input
        var changed = true
        while changed {
            changed = false
            var i = 0
            while i < words.count {
                var removed = false
                for n in stride(from: 3, through: 1, by: -1) where i + 2 * n <= words.count {
                    let a = words[i..<(i + n)], b = words[(i + n)..<(i + 2 * n)]
                    guard !a.contains(where: \.isBreak), !b.contains(where: \.isBreak),
                        a.map(\.key) == b.map(\.key),
                        // A copy that ends a sentence is a new sentence, not a stutter.
                        !a.dropLast().contains(where: \.endsSentence), !a.last!.endsSentence,
                        !(n == 1 && keepDoubled.contains(a.first!.key)),
                        // Plain words only: "5 5", "v2 v2", "foo.bar foo.bar" are kept as said.
                        a.allSatisfy({ !$0.core.isEmpty && $0.core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" } })
                    else { continue }
                    // Keep the second copy; it carries the natural punctuation that follows.
                    if isCapitalised(words[i]) && atSentenceStart(words, i) { capitalise(&words[i + n]) }
                    let lead = words[i].lead
                    words.removeSubrange(i..<(i + n))
                    if !lead.isEmpty, words[i].lead.isEmpty { words[i].lead = lead }
                    removed = true
                    changed = true
                    break
                }
                if !removed { i += 1 }
            }
        }
        return words
    }
}


/// Paragraph breaks from long pauses. Wispr Flow adds paragraphs to most 1–3 minute takes; this
/// does the same from the word timings alone and never changes a word: it only puts a blank line
/// between two words that had a long silence between them.
public enum Paragraphs {
    public struct Config: Sendable, Equatable {
        /// Only takes at least this long (seconds of audio) get paragraphs.
        public var minTakeSeconds = 20.0
        /// A silence at least this long between two words after a sentence end (. ! ? :) breaks.
        public var pauseSeconds = 1.2
        /// A silence this long breaks even mid-sentence.
        public var anywherePauseSeconds = 3.0
        /// No paragraph shorter than this many words (no one-word paragraphs from "Okay. [pause]").
        public var minWords = 8

        public init() {}
    }

    /// `text` with "\n\n" before every word that follows a long pause. Returns `text` unchanged
    /// when the take is short, or when `words` do not line up with `text` word for word (then
    /// it can't be sure where a break goes, and the words matter more than the breaks).
    public static func apply(_ text: String, words: [TranscriptWord], duration: Double, config: Config = Config()) -> String {
        guard duration >= config.minTakeSeconds, words.count > 1 else { return text }
        let tokens = text.split(whereSeparator: { $0 == " " })
        guard tokens.count == words.count, !text.contains("\n"),
            zip(tokens, words).allSatisfy({ $0.0 == Substring($0.1.text.trimmingCharacters(in: .whitespaces)) })
        else { return text }
        var out = String(tokens[0])
        var sinceBreak = 1
        for i in 1..<tokens.count {
            let gap = words[i].start - words[i - 1].end
            let endsSentence = tokens[i - 1].last.map { ".!?:".contains($0) } ?? false
            let remaining = tokens.count - i
            let breakHere = sinceBreak >= config.minWords && remaining >= config.minWords
                && (gap >= config.anywherePauseSeconds || (endsSentence && gap >= config.pauseSeconds))
            if breakHere {
                out += "\n\n"
                sinceBreak = 0
            } else {
                out += " "
            }
            out += tokens[i]
            sinceBreak += 1
        }
        return out
    }
}
