import Foundation

/// Text normalisation for scoring, matching `research/.../score.py`: lowercase, hyphens, slashes
/// and underscores split, punctuation stripped, apostrophes kept only inside words.
public enum ScoringText {
    public static let fillers: Set<String> = ["um", "uh", "umm", "uhh", "hmm", "mm", "mhm", "er", "ah", "eh"]

    public static func words(_ text: String, dropFillers: Bool = false) -> [String] {
        var out: [String] = []
        var current = ""
        let scalars = Array(text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").unicodeScalars)
        func isLetter(_ i: Int) -> Bool {
            i >= 0 && i < scalars.count && (("a"..."z").contains(scalars[i]))
        }
        func flush() {
            if !current.isEmpty, !(dropFillers && fillers.contains(current)) { out.append(current) }
            current = ""
        }
        for (i, s) in scalars.enumerated() {
            if ("a"..."z").contains(s) || ("0"..."9").contains(s) {
                current.unicodeScalars.append(s)
            } else if s == "'" && isLetter(i - 1) && isLetter(i + 1) {
                current.unicodeScalars.append(s)
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}

/// Word-level edit distance and alignment.
public enum WordAlignment {
    /// One aligned pair. `ref` or `hyp` is nil for a deletion or insertion.
    public struct Pair: Sendable, Equatable {
        public let ref: Int?
        public let hyp: Int?
        public var isMatch: Bool { ref != nil && hyp != nil }
    }

    /// Levenshtein distance over word arrays.
    public static func distance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Full alignment with backtrace. Substitutions come out as pairs with both sides set but
    /// different words; the caller compares the words to tell matches from substitutions.
    public static func align(_ ref: [String], _ hyp: [String]) -> [Pair] {
        let n = ref.count, m = hyp.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1))
                }
            }
        }
        var pairs: [Pair] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && d[i][j] == d[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1) {
                pairs.append(Pair(ref: i - 1, hyp: j - 1)); i -= 1; j -= 1
            } else if i > 0 && d[i][j] == d[i - 1][j] + 1 {
                pairs.append(Pair(ref: i - 1, hyp: nil)); i -= 1
            } else {
                pairs.append(Pair(ref: nil, hyp: j - 1)); j -= 1
            }
        }
        return pairs.reversed()
    }
}

/// Corpus-level word error rate: total edits over total reference words.
public struct WordErrorTally: Sendable {
    public private(set) var errors = 0
    public private(set) var words = 0

    public init() {}

    public var rate: Double { words == 0 ? 0 : Double(errors) / Double(words) }

    public mutating func add(reference: String, hypothesis: String, dropFillers: Bool = true) {
        let r = ScoringText.words(reference, dropFillers: dropFillers)
        let h = ScoringText.words(hypothesis, dropFillers: dropFillers)
        errors += WordAlignment.distance(r, h)
        words += r.count
    }
}
