import Foundation

/// Spelling and sound keys used to compare terms and heard forms.
///
/// - The spelling key is lowercase letters and digits only: "Next.js" and "nextjs" share it, and
///   "Ship Tiffin" has the same key as "ShipTiffin".
/// - The sound key is a small English sound code (Metaphone-like): voicing pairs merged
///   (b/p, d/t, g/k, v/f, z/s), vowels dropped after the first sound, "r" after a vowel dropped
///   (non-rhotic), doubled sounds collapsed. "real bird" and "Reelbird" both give `RLPT`;
///   "UTLDR" and "YouTLDR" both give `ATLTR`.
public enum SoundKey {
    public static func spelling(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII })
    }

    public static func sound(_ s: String) -> String {
        let letters = Array(spelling(s))
        guard !letters.isEmpty else { return "" }
        func isVowel(_ c: Character) -> Bool { "aeiouy".contains(c) }
        // 1. Map letters (with one letter of look-ahead) to sound symbols. Vowels become "a";
        //    y/w/h become "a" too (glides), so "you" and "u" start the same.
        var symbols: [Character] = []
        var i = 0
        while i < letters.count {
            let c = letters[i]
            let next: Character? = i + 1 < letters.count ? letters[i + 1] : nil
            var out: String
            var skip = 1
            switch c {
            case "a", "e", "i", "o", "u", "y", "w": out = "a"
            case "h": out = "a"
            case "p": if next == "h" { out = "f"; skip = 2 } else { out = "p" }
            case "b": out = "p"
            case "s":
                if next == "h" { out = "x"; skip = 2 }
                else if next == "c", i + 2 < letters.count, letters[i + 2] == "h" { out = "sk"; skip = 3 }
                else { out = "s" }
            case "z": out = "s"
            case "c":
                if next == "h" { out = "x"; skip = 2 }
                else if next == "k" { out = "k"; skip = 2 }
                else if let n = next, "eiy".contains(n) { out = "s" }
                else { out = "k" }
            case "k", "q": out = "k"
            case "g":
                if next == "h" { out = "k"; skip = 2 }
                else if let n = next, "eiy".contains(n) { out = "j" }
                else { out = "k" }
            case "j": out = "j"
            case "t": if next == "h" { out = "0"; skip = 2 } else { out = "t" }
            case "d": if next == "g" { out = "j"; skip = 2 } else { out = "t" }
            case "v", "f": out = "f"
            case "x": out = "ks"
            default: out = String(c)  // l, m, n, r, digits
            }
            symbols.append(contentsOf: out)
            i += skip
        }
        // 2. "r" after a vowel and before a consonant or the end is silent.
        var kept: [Character] = []
        for (k, c) in symbols.enumerated() {
            if c == "r", k > 0, symbols[k - 1] == "a", k + 1 == symbols.count || symbols[k + 1] != "a" { continue }
            kept.append(c)
        }
        // 3. First sound: any vowel becomes "A"; later vowels drop; repeats collapse.
        var key = ""
        for (k, c) in kept.enumerated() {
            if c == "a" {
                if k == 0 { key.append("A") }
                continue
            }
            if let last = key.last, last == Character(c.uppercased()) { continue }
            key.append(Character(c.uppercased()))
        }
        return key
    }

    /// 1 − edit distance / longer length, on characters.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        let longest = max(x.count, y.count)
        guard longest > 0 else { return 1 }
        return 1 - Double(editDistance(x, y)) / Double(longest)
    }

    public static func editDistance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
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

    /// How alike two written forms sound and look: the mean of sound-key and spelling-key similarity.
    public static func likeness(_ a: String, _ b: String) -> (sound: Double, spelling: Double) {
        (similarity(sound(a), sound(b)), similarity(spelling(a), spelling(b)))
    }
}

/// Words that are ordinary English for this user. A heard form made only of these is risky to
/// rewrite, and a term spelled as one ("Dibs", "Fable") is never the target of a sound-alike swap.
public struct CommonWords: Sendable {
    public let words: Set<String>

    public init(_ words: Set<String>) {
        self.words = Set(words.map { $0.lowercased() })
    }

    /// The system word list (`/usr/share/dict/words`), lowercased. Empty if missing.
    public static func system(path: String = "/usr/share/dict/words") -> CommonWords {
        CommonWords(TermHarvest.loadSystemDictionary(path: path))
    }

    /// True when the word (or a simple inflection of it) is in the list.
    public func contains(_ word: String) -> Bool {
        let key = SoundKey.spelling(word)
        guard !key.isEmpty else { return false }
        if words.contains(key) { return true }
        for suffix in ["s", "es", "ed", "d", "ing", "er", "ly"] where key.hasSuffix(suffix) && key.count > suffix.count + 2 {
            let stem = String(key.dropLast(suffix.count))
            if words.contains(stem) || words.contains(stem + "e") { return true }
        }
        return false
    }

    /// True when every word of a phrase is common.
    public func allCommon(_ phrase: String) -> Bool {
        let parts = phrase.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
        return !parts.isEmpty && parts.allSatisfy { contains(String($0)) }
    }
}
