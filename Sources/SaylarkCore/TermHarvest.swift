import Foundation

/// A word as written, plus the form used to compare words (lowercase letters and digits only).
public struct TextToken: Sendable, Equatable {
    public let text: String
    public let key: String
    /// True for the first word of a sentence or line.
    public let sentenceStart: Bool

    /// Splits on whitespace and strips punctuation at the edges; inner marks stay ("Next.js").
    public static func tokenize(_ s: String) -> [TextToken] {
        var out: [TextToken] = []
        var start = true
        for raw in s.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            let key = String(trimmed.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            if !key.isEmpty { out.append(TextToken(text: trimmed, key: key, sentenceStart: start)) }
            if let last = raw.last { start = ".!?:\n".contains(last) } else { start = false }
            if raw.contains("\n") { start = true }
        }
        return out
    }
}

/// Finds words in a reference text that the recogniser got wrong and that look like names or
/// jargon, for seeding the dictionary.
public struct TermHarvest: Sendable {
    /// Lowercased words from a system word list.
    public let dictionary: Set<String>

    public init(dictionary: Set<String>) {
        self.dictionary = dictionary
    }

    public static func loadSystemDictionary(path: String = "/usr/share/dict/words") -> Set<String> {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").map { $0.lowercased() })
    }

    /// Rare: camelCase, letters mixed with digits, capitalised mid-sentence, or not a dictionary word.
    public func isRare(_ t: TextToken) -> Bool {
        let chars = Array(t.text)
        let letters = chars.filter(\.isLetter)
        // Letters mixed with digits ("M4", "GPT5"); plain numbers are not terms.
        if chars.contains(where: \.isNumber) { return !letters.isEmpty }
        guard letters.count >= 2 else { return false }
        // Contractions ("it'd", "you're") are ordinary words the word list happens to lack.
        if t.text.contains("'") || t.text.contains("\u{2019}") || t.key == "ok" { return false }
        for i in 1..<chars.count where chars[i].isUppercase && chars[i - 1].isLowercase { return true }
        if chars.first?.isUppercase == true, !t.sentenceStart {
            // All-caps short words like "OK" are not names.
            if letters.allSatisfy(\.isUppercase), letters.count <= 2 { return false }
            return true
        }
        return !isDictionaryWord(t.key)
    }

    func isDictionaryWord(_ key: String) -> Bool {
        if dictionary.contains(key) { return true }
        // Simple inflections: plurals, -ed, -ing, possessives with the apostrophe dropped.
        for suffix in ["s", "es", "ed", "d", "ing", "er", "ly"] where key.hasSuffix(suffix) && key.count > suffix.count + 2 {
            let stem = String(key.dropLast(suffix.count))
            if dictionary.contains(stem) || dictionary.contains(stem + "e") { return true }
        }
        return false
    }

    /// One place where the recogniser's words differ from the reference and the reference has a rare word.
    public struct Miss: Sendable, Equatable {
        /// The rare reference words, as written.
        public let term: String
        /// What the recogniser wrote there.
        public let heard: String
        /// Same letters, only spacing or punctuation differ ("Ship Tiffin" for "ShipTiffin").
        public let formatOnly: Bool
        /// A few reference words around the term.
        public let context: String
    }

    /// Result of comparing one recognition against one reference.
    public struct Comparison: Sendable {
        public var misses: [Miss] = []
        /// Grouping keys of rare reference words the recogniser got right.
        public var hits: [String] = []
    }

    /// Grouping key for a term: lowercase letters and digits, spaces removed.
    public static func groupKey(_ term: String) -> String {
        String(term.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    public func compare(reference: String, heard: String) -> Comparison {
        let ref = TextToken.tokenize(reference), hyp = TextToken.tokenize(heard)
        let pairs = WordAlignment.align(ref.map(\.key), hyp.map(\.key))
        var out = Comparison()
        var i = 0
        while i < pairs.count {
            let p = pairs[i]
            if let r = p.ref, let h = p.hyp, ref[r].key == hyp[h].key {
                if isRare(ref[r]) { out.hits.append(Self.groupKey(ref[r].text)) }
                i += 1
                continue
            }
            // Gather the whole run of differences.
            var j = i
            var refIdx: [Int] = [], hypIdx: [Int] = []
            while j < pairs.count {
                let q = pairs[j]
                if let r = q.ref, let h = q.hyp, ref[r].key == hyp[h].key { break }
                if let r = q.ref { refIdx.append(r) }
                if let h = q.hyp { hypIdx.append(h) }
                j += 1
            }
            i = j
            guard let firstRare = refIdx.firstIndex(where: { isRare(ref[$0]) }),
                let lastRare = refIdx.lastIndex(where: { isRare(ref[$0]) })
            else { continue }
            let termIdx = Array(refIdx[firstRare...lastRare])
            let term = termIdx.map { ref[$0].text }.joined(separator: " ")
            let heardText = hypIdx.map { hyp[$0].text }.joined(separator: " ")
            let refAll = refIdx.map { ref[$0].key }.joined()
            let hypAll = hypIdx.map { hyp[$0].key }.joined()
            let lo = max(0, termIdx.first! - 4), hi = min(ref.count, termIdx.last! + 5)
            out.misses.append(Miss(
                term: term, heard: heardText, formatOnly: !hypAll.isEmpty && refAll == hypAll,
                context: ref[lo..<hi].map(\.text).joined(separator: " ")))
        }
        return out
    }
}

/// Finds where a short text (a dictation) sits inside a longer one (a sent message), word by word.
public enum FuzzyContainment {
    public struct Match: Sendable, Equatable {
        /// 1 minus word edits per word of the short text (1 = found exactly).
        public let score: Double
        /// Tokens of the long text that the short text lines up with.
        public let range: Range<Int>
    }

    /// Approximate substring search: the span of `long` with the fewest word edits to `short`.
    public static func match(_ short: [String], in long: [String]) -> Match? {
        guard !short.isEmpty, !long.isEmpty else { return nil }
        let n = short.count, m = long.count
        // d[i][j]: edits to turn short[..<i] into a span of long ending at j. Starting anywhere is free.
        var d = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = Int32(i) }
        for i in 1...n {
            for j in 1...m {
                let sub = d[i - 1][j - 1] + (short[i - 1] == long[j - 1] ? 0 : 1)
                d[i][j] = min(sub, d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        var end = 1
        for j in 1...m where d[n][j] < d[n][end] { end = j }
        var i = n, j = end
        while i > 0 && j > 0 {
            if d[i][j] == d[i - 1][j - 1] + (short[i - 1] == long[j - 1] ? 0 : 1) {
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return Match(score: 1 - Double(d[n][end]) / Double(n), range: j..<end)
    }
}
