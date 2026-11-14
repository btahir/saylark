import Foundation

/// Names metric: for a list of target terms, how many occurrences in the reference the
/// hypothesis got right, and how many it wrote where the reference has none.
///
/// Counting is per take and order-free: `correct = min(ref, hyp)` and
/// `falseInsertions = max(0, hyp − ref)` for each term. Matching is on whitespace tokens reduced to
/// lowercase letters and digits ("Next.js" = "nextjs"), so case and punctuation never count,
/// but spacing does: "Ship Tiffin" is not "ShipTiffin" ("lenient" counts those too).
public struct TermRecall: Sendable {
    public struct Tally: Codable, Sendable, Equatable {
        public var reference = 0
        public var hypothesis = 0
        public var correct = 0
        public var falseInsertions = 0
        public var lenientCorrect = 0
        public init() {}

        public var recall: Double { reference == 0 ? .nan : Double(correct) / Double(reference) }

        mutating func add(_ o: Tally) {
            reference += o.reference; hypothesis += o.hypothesis; correct += o.correct
            falseInsertions += o.falseInsertions; lenientCorrect += o.lenientCorrect
        }
    }

    public let terms: [String]
    let keys: [[String]]
    public private(set) var byTerm: [String: Tally] = [:]

    public init(terms: [String]) {
        self.terms = terms
        keys = terms.map { $0.split(whereSeparator: \.isWhitespace).map { SoundKey.spelling(String($0)) }.filter { !$0.isEmpty } }
    }

    static func tokens(_ text: String) -> [String] {
        text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).map { SoundKey.spelling(String($0)) }.filter { !$0.isEmpty }
    }

    static func count(_ k: [String], in toks: [String], lenient: Bool) -> Int {
        guard !k.isEmpty, toks.count >= k.count else { return 0 }
        var n = 0
        var i = 0
        while i + k.count <= toks.count {
            if (0..<k.count).allSatisfy({ toks[i + $0] == k[$0] }) { n += 1; i += k.count; continue }
            if lenient {
                // Same letters split differently ("ship tiffin" for "shiptiffin").
                let joined = k.joined()
                var acc = ""
                var j = i
                while j < toks.count, acc.count < joined.count { acc += toks[j]; j += 1 }
                if acc == joined, j - i != k.count { n += 1; i = j; continue }
            }
            i += 1
        }
        return n
    }

    /// Scores one take and adds it to the totals. Returns the take's own tallies (terms with any count).
    @discardableResult
    public mutating func add(reference: String, hypothesis: String) -> [String: Tally] {
        let r = Self.tokens(reference), h = Self.tokens(hypothesis)
        var out: [String: Tally] = [:]
        for (term, k) in zip(terms, keys) {
            let rc = Self.count(k, in: r, lenient: false), hc = Self.count(k, in: h, lenient: false)
            guard rc > 0 || hc > 0 else { continue }
            var t = Tally()
            t.reference = rc
            t.hypothesis = hc
            t.correct = min(rc, hc)
            t.falseInsertions = max(0, hc - rc)
            t.lenientCorrect = min(rc, Self.count(k, in: h, lenient: true))
            out[term] = t
            byTerm[term, default: Tally()].add(t)
        }
        return out
    }

    public func total(_ subset: Set<String>? = nil) -> Tally {
        var t = Tally()
        for (term, x) in byTerm where subset?.contains(term) ?? true { t.add(x) }
        return t
    }
}
