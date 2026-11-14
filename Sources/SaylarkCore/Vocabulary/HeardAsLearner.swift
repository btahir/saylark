import Foundation

/// Learns how Saylark's own recogniser mishears the user's terms ("codecs" for "Codex", "level
/// labs" for "ElevenLabs") by lining up what it wrote against a reference for the same take:
/// an answer key in evals (`saylark vocab eval`).
///
/// Every heard-as form is gated by measured precision. `hits` counts the takes' places where the
/// recogniser wrote the form and the reference had the term; `seen` counts every place the
/// recogniser wrote the form at all. A form goes live only with enough hits and a high share
/// `hits / seen`, so a word the user also means literally ("cloud", "fall") stays out unless the
/// data says otherwise. A live form whose share drops is retired.
public struct HeardAsLearner: Codable, Sendable, Equatable {
    public struct Rules: Codable, Sendable, Equatable {
        public var minHits = 2
        public var minPrecision = 0.75
        /// A single ordinary word ("cloud", "fall", "strike") needs more and cleaner evidence.
        public var commonMinHits = 3
        public var commonMinPrecision = 0.9
        /// A live form is retired when its share falls below this (hysteresis below `minPrecision`).
        public var retirePrecision = 0.6
        /// Longest heard-as form, in words.
        public var maxSpan = 3
        /// Minimum spelling-or-sound likeness between the heard form and the term.
        public var minLikeness = 0.5
        /// Longest stretch of unmatched recogniser words searched for the form.
        public var maxGap = 8

        public init() {}
    }

    public struct Candidate: Codable, Sendable, Equatable, Identifiable {
        public enum State: String, Codable, Sendable { case candidate, live, retired }

        /// As the recogniser wrote it the first time ("level labs").
        public var form: String
        /// Word keys joined by spaces ("level labs"), used to count `seen`.
        public var formKey: String
        public var termKey: String
        public var termSpelling: String
        public var hits: Int
        public var seen: Int
        public var firstSeen: Date
        public var lastSeen: Date
        public var state: State
        /// Single ordinary word: the stricter gate applies.
        public var isCommon: Bool
        /// In the user's own writing (references, past dictations): how often he wrote the form
        /// itself ("codecs", meaning codecs) and the term. A form he often means literally fails.
        public var literal: Int?
        public var termUses: Int?
        /// The form is already a known mishearing of the term from another source (Wispr wrote
        /// "UTLDR" for YouTLDR): its appearances in past writing are Wispr's mistakes, not literal uses.
        public var knownMishearing: Bool?

        /// Share of his own uses of the form-or-term that are the form: the chance a literal use
        /// gets rewritten. Nil without evidence.
        public var literalShare: Double? {
            guard knownMishearing != true else { return nil }
            let l = literal ?? 0, t = termUses ?? 0
            return l + t == 0 ? nil : Double(l) / Double(l + t)
        }

        public var id: String { formKey + "|" + termKey }
        public var precision: Double { seen == 0 ? 0 : Double(hits) / Double(seen) }
    }

    /// One aligned mishearing in one take.
    public struct Pair: Sendable, Equatable {
        public var form: String
        public var formKey: String
        public var termKey: String
        public var termSpelling: String
        /// The form is already a heard-as form of the term from another source.
        public var known = false
    }

    public var rules: Rules
    public private(set) var candidates: [String: Candidate] = [:]

    public init(rules: Rules = Rules(), candidates: [Candidate] = []) {
        self.rules = rules
        self.candidates = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    public var live: [Candidate] { candidates.values.filter { $0.state == .live }.sorted { $0.hits > $1.hits || ($0.hits == $1.hits && $0.id < $1.id) } }
    public var all: [Candidate] { candidates.values.sorted { $0.hits > $1.hits || ($0.hits == $1.hits && $0.id < $1.id) } }

    // MARK: - Learning

    /// Learns from one take. Returns the candidates whose state changed (went live or retired).
    @discardableResult
    public mutating func learn(heard: String, reference: String, terms: [VocabularyTerm], common: CommonWords, at: Date) -> [Candidate] {
        let pairs = Self.pairs(heard: heard, reference: reference, terms: terms, rules: rules)
        let words = Self.words(heard).map(\.key)
        for p in pairs {
            let id = p.formKey + "|" + p.termKey
            if candidates[id] == nil {
                candidates[id] = Candidate(
                    form: p.form, formKey: p.formKey, termKey: p.termKey, termSpelling: p.termSpelling, hits: 0, seen: 0,
                    firstSeen: at, lastSeen: at, state: .candidate, isCommon: !p.formKey.contains(" ") && common.contains(p.form))
            }
            candidates[id]!.hits += 1
            candidates[id]!.lastSeen = max(candidates[id]!.lastSeen, at)
            if p.known { candidates[id]!.knownMishearing = true }
        }
        // Every place this take wrote a known form counts toward its denominator.
        let counts = Self.occurrences(of: Set(candidates.values.map(\.formKey)), in: words, maxSpan: rules.maxSpan)
        for id in Array(candidates.keys) {
            let c = counts[candidates[id]!.formKey] ?? 0
            // A hit is always also a sighting, even if alignment split the form oddly.
            let hitsHere = pairs.filter { $0.formKey + "|" + $0.termKey == id }.count
            candidates[id]!.seen += max(c, hitsHere)
        }
        // The reference is the user's own writing: count his literal uses of each form.
        noteWriting([reference])
        return updateStates()
    }

    /// Counts, in the user's own writing, each candidate's form and term ("codecs" vs "Codex").
    /// The references fed to `learn` are counted automatically; pass past writing here too.
    public mutating func noteWriting(_ texts: [String]) {
        guard !candidates.isEmpty else { return }
        let forms = Set(candidates.values.map(\.formKey))
        let terms = Set(candidates.values.map(\.termKey))
        var formCount: [String: Int] = [:], termCount: [String: Int] = [:]
        for text in texts {
            let w = Self.words(text).map(\.key)
            for (k, v) in Self.occurrences(of: forms, in: w, maxSpan: rules.maxSpan) { formCount[k, default: 0] += v }
            // Terms by joined key over 1-3 words ("Eleven Labs" counts for ElevenLabs).
            for n in 1...rules.maxSpan where n <= w.count {
                for i in 0...(w.count - n) {
                    let k = w[i..<(i + n)].joined()
                    if terms.contains(k) { termCount[k, default: 0] += 1 }
                }
            }
        }
        for id in Array(candidates.keys) {
            let c = candidates[id]!
            if let f = formCount[c.formKey] { candidates[id]!.literal = (c.literal ?? 0) + f }
            if let t = termCount[c.termKey] { candidates[id]!.termUses = (c.termUses ?? 0) + t }
        }
    }

    /// Batch learning (backfills, evals): hits from every take, and `seen` counted over all of
    /// them, so a form first matched late still counts the earlier places it was written. States
    /// are decided once, on the totals. Adds to the counts already held.
    public mutating func learnAll(_ takes: [(heard: String, reference: String, at: Date)], terms: [VocabularyTerm], common: CommonWords) {
        let prior = candidates
        var batchHits: [String: Int] = [:]
        for t in takes {
            for p in Self.pairs(heard: t.heard, reference: t.reference, terms: terms, rules: rules) {
                let id = p.formKey + "|" + p.termKey
                batchHits[id, default: 0] += 1
                if candidates[id] == nil {
                    candidates[id] = Candidate(
                        form: p.form, formKey: p.formKey, termKey: p.termKey, termSpelling: p.termSpelling, hits: 0, seen: 0,
                        firstSeen: t.at, lastSeen: t.at, state: .candidate, isCommon: !p.formKey.contains(" ") && common.contains(p.form))
                }
                candidates[id]!.lastSeen = max(candidates[id]!.lastSeen, t.at)
                candidates[id]!.firstSeen = min(candidates[id]!.firstSeen, t.at)
                if p.known { candidates[id]!.knownMishearing = true }
            }
        }
        let forms = Set(candidates.values.map(\.formKey))
        var batchSeen: [String: Int] = [:]
        for t in takes {
            for (k, v) in Self.occurrences(of: forms, in: Self.words(t.heard).map(\.key), maxSpan: rules.maxSpan) { batchSeen[k, default: 0] += v }
        }
        for id in Array(candidates.keys) {
            let h = batchHits[id] ?? 0
            candidates[id]!.hits = (prior[id]?.hits ?? 0) + h
            candidates[id]!.seen = (prior[id]?.seen ?? 0) + max(h, batchSeen[candidates[id]!.formKey] ?? 0)
        }
        noteWriting(takes.map(\.reference))
        updateStates()
    }

    /// Drops a candidate (the user removed the alias).
    public mutating func remove(formKey: String, termKey: String) {
        candidates[formKey + "|" + termKey] = nil
    }

    /// Re-decides every state from the counts (after `noteWriting`).
    @discardableResult
    public mutating func refreshStates() -> [Candidate] { updateStates() }

    @discardableResult
    mutating func updateStates() -> [Candidate] {
        var changed: [Candidate] = []
        for id in Array(candidates.keys) {
            var c = candidates[id]!
            let minHits = c.isCommon ? rules.commonMinHits : rules.minHits
            let minPrecision = c.isCommon ? rules.commonMinPrecision : rules.minPrecision
            // He rarely writes the form itself: a literal use would be rewritten at most this often.
            let literalOK = (c.literalShare ?? 0) <= 1 - minPrecision
            let passes = c.hits >= minHits && c.precision >= minPrecision && literalOK
            let next: Candidate.State
            switch c.state {
            case .live: next = c.precision < rules.retirePrecision || (c.literalShare ?? 0) > 1 - rules.retirePrecision ? .retired : .live
            case .candidate, .retired: next = passes ? .live : c.state
            }
            if next != c.state {
                c.state = next
                changed.append(c)
                candidates[id] = c
            }
        }
        return changed
    }

    /// Terms with this learner's live forms attached as `.asr` aliases (older `.asr` aliases are
    /// replaced). A form that is itself another term is never attached.
    public func applying(to terms: [VocabularyTerm]) -> [VocabularyTerm] {
        let keys = Set(terms.map(\.key))
        var byTerm: [String: [Candidate]] = [:]
        for c in live { byTerm[c.termKey, default: []].append(c) }
        return terms.map { t in
            var t = t
            t.aliases.removeAll { $0.source == .asr }
            for c in byTerm[t.key] ?? [] {
                let alias = HeardAs(form: c.form, count: c.hits, source: .asr, seen: c.seen)
                // A form already known from another source ("real bird", from Wispr's mistakes) is kept
                // beside the measured one; the swapper prefers the measured one.
                guard !keys.contains(alias.key), alias.key != t.key else { continue }
                t.aliases.append(alias)
            }
            return t
        }
    }

    // MARK: - Alignment

    static let edgeWords: Set<String> = ["a", "an", "the", "and", "or", "to", "of", "in", "on", "for", "is", "it", "so", "but", "my", "our", "you", "we", "i"]

    static let fillers: Set<String> = ["uh", "um", "uhm", "umm", "er", "erm", "ah", "hmm", "mm"]

    /// Words with their spelling keys, fillers dropped.
    public static func words(_ text: String) -> [(text: String, key: String)] {
        text.split(whereSeparator: \.isWhitespace).compactMap { w in
            let core = TermSwapper.split(String(w)).core
            let key = SoundKey.spelling(core)
            return key.isEmpty || fillers.contains(key) ? nil : (core, key)
        }
    }

    /// Where the reference has a term and the recogniser wrote something else that looks or
    /// sounds like it, between the nearest words both agree on.
    public static func pairs(heard: String, reference: String, terms: [VocabularyTerm], rules: Rules = Rules()) -> [Pair] {
        let termByKey = Dictionary(terms.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let ref = words(reference), hyp = words(heard)
        guard !ref.isEmpty, !hyp.isEmpty else { return [] }
        let matches = align(ref.map(\.key), hyp.map(\.key))  // (refIndex, hypIndex) of equal words, increasing
        var out: [Pair] = []
        var i = 0
        while i < ref.count {
            var span: (n: Int, term: VocabularyTerm)?
            for n in stride(from: min(rules.maxSpan, ref.count - i), through: 1, by: -1) {
                if let t = termByKey[ref[i..<(i + n)].map(\.key).joined()] { span = (n, t); break }
            }
            guard let found = span else { i += 1; continue }
            let n = found.n, term = found.term
            defer { i += n }
            let left = matches.last { $0.0 < i }?.1 ?? -1
            let right = matches.first { $0.0 >= i + n }?.1 ?? hyp.count
            let gap = (left + 1)..<right
            // Heard right (all words matched) or nothing to compare.
            guard !gap.isEmpty, gap.count <= rules.maxGap else { continue }
            if hyp[gap].map(\.key).joined() == term.key { continue }
            var best: (score: Double, range: Range<Int>)?
            var spacedRight = false
            for m in 1...rules.maxSpan {
                for j in gap where j + m <= gap.upperBound {
                    let joined = hyp[j..<(j + m)].map(\.key).joined()
                    if joined == term.key { spacedRight = true }
                    let l = SoundKey.likeness(joined, term.spelling)
                    let score = max(l.sound, l.spelling)
                    if score >= rules.minLikeness, best == nil || score > best!.score { best = (score, j..<(j + m)) }
                }
            }
            // Same letters, other spacing: the spacing rule's job, not an alias.
            guard let b = best, !spacedRight else { continue }
            var w = hyp[b.range]
            // "a Level Labs": a short function word at the edge is not part of the form.
            while w.count > 1, let f = w.first, f.key.count <= 3, edgeWords.contains(f.key) { w = w.dropFirst() }
            while w.count > 1, let l = w.last, l.key.count <= 3, edgeWords.contains(l.key) { w = w.dropLast() }
            // "Opus5.5", "to10k": a word glued to a number is the number-spacing rule's job; as an
            // alias it would drop the number.
            if w.contains(where: { $0.key.contains(where: \.isNumber) && $0.key.contains(where: \.isLetter) }) { continue }
            let joined = w.map(\.key).joined()
            out.append(Pair(
                form: w.map(\.text).joined(separator: " "), formKey: w.map(\.key).joined(separator: " "), termKey: term.key, termSpelling: term.spelling,
                known: term.aliases.contains { $0.key == joined }))
        }
        return out
    }

    /// Word-level alignment (edit distance); returns the pairs of equal words on the best path.
    static func align(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        if n > 0, m > 0 {
            for i in 1...n {
                for j in 1...m {
                    d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                }
            }
        }
        var out: [(Int, Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            if a[i - 1] == b[j - 1], d[i][j] == d[i - 1][j - 1] {
                out.append((i - 1, j - 1)); i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j - 1] + 1 {
                i -= 1; j -= 1
            } else if d[i][j] == d[i - 1][j] + 1 {
                i -= 1
            } else {
                j -= 1
            }
        }
        return out.reversed()
    }

    /// How often each form (space-joined word keys) occurs in these words.
    static func occurrences(of forms: Set<String>, in words: [String], maxSpan: Int) -> [String: Int] {
        guard !forms.isEmpty else { return [:] }
        var out: [String: Int] = [:]
        for n in 1...maxSpan where n <= words.count {
            for i in 0...(words.count - n) {
                let f = words[i..<(i + n)].joined(separator: " ")
                if forms.contains(f) { out[f, default: 0] += 1 }
            }
        }
        return out
    }
}
