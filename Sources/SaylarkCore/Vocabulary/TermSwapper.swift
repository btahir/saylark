import Foundation

/// One correction applied to a transcript, with the reason. Word indices refer to the words the
/// change was proposed on.
public struct TermChange: Codable, Sendable, Equatable {
    public enum Rule: String, Codable, Sendable {
        /// Same letters, different spacing or case ("Ship Tiffin" → "ShipTiffin").
        case spacing
        /// A known heard-as form ("UTLDR" → "YouTLDR").
        case alias
        /// An unsure word that sounds and looks like a term, with no alias on record.
        case sound
        /// FluidAudio's CTC keyword spotter + rescorer preferred the term acoustically.
        case ctc
        /// A term glued to the number after it ("Opus5.5" → "Opus 5.5").
        case number
    }

    public var start: Int
    public var count: Int
    public var original: String
    public var replacement: String
    public var rule: Rule
    /// Lowest recogniser confidence over the replaced words.
    public var confidence: Float
    public var detail: String

    public init(start: Int, count: Int, original: String, replacement: String, rule: Rule, confidence: Float, detail: String = "") {
        self.start = start
        self.count = count
        self.original = original
        self.replacement = replacement
        self.rule = rule
        self.confidence = confidence
        self.detail = detail
    }
}

/// The cheap text-level fix: swaps known heard-as forms and unsure sound-alikes for dictionary
/// terms. Pure and fast (well under a millisecond for a window).
///
/// Safety rules, because a wrong "correction" is worse than a miss:
/// - Spacing/case fixes ("eleven labs" → "ElevenLabs") are applied for trusted terms. A term only
///   seen in past dictations gets no case-only fix and no join of ordinary words ("sign up").
/// - Two or three ordinary words with a one- or two-letter word among them ("up I") never match.
/// - A heard-as form that is not ordinary English ("UTLDR", "Omami") of a trusted term (project
///   name, Wispr dictionary) is swapped whenever seen (at least `minAliasCount` sightings on record).
/// - Any other heard-as form ("real bird", or "Headsner" for Hetzner, a term only seen in past
///   dictations) is swapped only when the recogniser was unsure of it (lowest word confidence
///   below `confidence`).
/// - A sound-alike with no alias on record is swapped only if it is unsure, not ordinary English,
///   and the term itself is distinctive (not a dictionary word, five letters or more).
/// - Nothing is ever rewritten into a term from a span that is itself a known term.
public struct TermSwapper: Sendable {
    public struct Config: Sendable, Equatable {
        /// Words below this confidence count as unsure.
        public var confidence: Float = 0.6
        public var minAliasCount = 2
        /// Sound-alike swap: minimum sound-key and spelling-key similarity.
        public var soundMin = 0.8
        public var spellingMin = 0.6
        /// Sound-alike swaps on/off (aliases and spacing stay on).
        public var soundAlike = true
        /// Heard-as forms learned from Saylark's own recogniser (`.asr` source) on/off.
        public var learnedAliases = true
        /// Split "Opus5.5" into "Opus 5.5" for terms the user writes apart from numbers.
        public var splitNumbers = true
        public var maxSpan = 3

        public init() {}
    }

    struct Entry: Sendable {
        let spelling: String
        let key: String
        let sound: String
        let wordCount: Int
        let isCommonWord: Bool
        /// From a project name, Wispr's dictionary or a manual entry.
        let trusted: Bool
        /// Written apart from a following number in the user's own text.
        let apartFromNumbers: Bool
    }

    struct AliasEntry: Sendable {
        let term: Int
        let count: Int
        /// The heard-as form came from a trusted source (Wispr's dictionary, manual).
        let trusted: Bool
        /// The term itself comes from a trusted source (a project name, Wispr's dictionary, manual).
        let trustedTerm: Bool
        let allCommon: Bool
        /// Learned from Saylark's own recogniser and passed the precision gate (`HeardAsLearner`).
        let learned: Bool

        /// Swapped even when the recogniser was sure: an odd spelling ("UTLDR") of a trusted term,
        /// or a form that measured precision says nearly always means the term.
        var unconditional: Bool { learned || (!allCommon && (trusted || trustedTerm)) }
    }

    let entries: [Entry]
    let byKey: [String: Int]
    let aliases: [String: AliasEntry]
    let common: CommonWords
    public let config: Config

    public init(terms: [VocabularyTerm], common: CommonWords, config: Config = Config()) {
        var entries: [Entry] = [], byKey: [String: Int] = [:]
        for t in terms where byKey[t.key] == nil {
            byKey[t.key] = entries.count
            entries.append(Entry(
                spelling: t.spelling, key: t.key, sound: t.sound,
                wordCount: t.spelling.split(whereSeparator: \.isWhitespace).count, isCommonWord: t.isCommonWord,
                trusted: t.bestSource.isTrusted, apartFromNumbers: t.isWrittenApartFromNumbers))
        }
        var aliases: [String: AliasEntry] = [:]
        for t in terms {
            guard let ti = byKey[t.key] else { continue }
            for a in t.aliases where byKey[a.key] == nil {
                if a.source == .asr, !config.learnedAliases { continue }
                let entry = AliasEntry(
                    term: ti, count: a.count, trusted: a.source.isTrusted, trustedTerm: t.bestSource.isTrusted, allCommon: common.allCommon(a.form),
                    learned: a.source == .asr)
                // One heard form, two terms: keep the measured one, else the better-attested one.
                if let old = aliases[a.key], old.learned && !entry.learned || (old.learned == entry.learned && old.count >= entry.count) { continue }
                aliases[a.key] = entry
            }
        }
        self.entries = entries
        self.byKey = byKey
        self.aliases = aliases
        self.common = common
        self.config = config
    }

    /// Splits a word into leading punctuation, core and trailing punctuation.
    public static func split(_ word: String) -> (lead: String, core: String, trail: String) {
        let chars = Array(word)
        var a = 0, b = chars.count
        while a < b, !(chars[a].isLetter || chars[a].isNumber) { a += 1 }
        while b > a, !(chars[b - 1].isLetter || chars[b - 1].isNumber) { b -= 1 }
        return (String(chars[..<a]), String(chars[a..<b]), String(chars[b...]))
    }

    /// Proposes non-overlapping changes, left to right, longest span first.
    public func propose(_ words: [TranscriptWord]) -> [TermChange] {
        let parts = words.map { Self.split($0.text) }
        let keys = parts.map { SoundKey.spelling($0.core) }
        var out: [TermChange] = []
        var i = 0
        outer: while i < words.count {
            guard !keys[i].isEmpty else { i += 1; continue }
            if config.splitNumbers, let change = numberSplit(at: i, words: words, parts: parts) {
                out.append(change)
                i += 1
                continue
            }
            for n in stride(from: min(config.maxSpan, words.count - i), through: 1, by: -1) {
                // Punctuation inside a span ("bird. Then") means it is not one name.
                if n > 1, (0..<(n - 1)).contains(where: { !parts[i + $0].trail.isEmpty }) || (1..<n).contains(where: { !parts[i + $0].lead.isEmpty }) { continue }
                let span = i..<(i + n)
                let key = span.map { keys[$0] }.joined()
                guard !key.isEmpty else { continue }
                let original = span.map { parts[$0].core }.joined(separator: " ")
                let conf = span.map { words[$0].confidence }.min() ?? 1
                // Ordinary short words glued together ("up I", "a is") are too easy to hit by chance.
                if n > 1, common.allCommon(original), span.contains(where: { parts[$0].core.count <= 2 }) { continue }
                if let ti = byKey[key] {
                    let e = entries[ti]
                    // Already right, or a common-word term ("dibs", "Lookout") where neither case nor
                    // spacing is evidence ("look out" is ordinary English).
                    if original == e.spelling || e.isCommonWord { i += n; continue outer }
                    if n == e.wordCount && original.lowercased() == e.spelling.lowercased() && n > 1 { i += n; continue outer }
                    // A term only seen in past dictations earns no case-only fix ("okay" -> "Okay") and no
                    // lowercase join of ordinary words ("sign up" -> "signup"); "open router" -> "OpenRouter" stays.
                    if !e.trusted {
                        if n == 1, original.lowercased() == e.spelling.lowercased() { i += n; continue outer }
                        if n > 1, common.allCommon(original), e.spelling == e.spelling.lowercased() { i += n; continue outer }
                    }
                    out.append(TermChange(start: i, count: n, original: original, replacement: e.spelling, rule: .spacing, confidence: conf, detail: "same letters"))
                    i += n
                    continue outer
                }
                if let a = aliases[key], a.count >= config.minAliasCount || a.trusted || a.learned {
                    let e = entries[a.term]
                    if a.unconditional || conf < config.confidence {
                        let why = a.unconditional ? "heard-as form (\(a.count)x)" : "heard-as form (\(a.count)x), unsure \(String(format: "%.2f", conf))"
                        out.append(TermChange(start: i, count: n, original: original, replacement: e.spelling, rule: .alias, confidence: conf, detail: why))
                        i += n
                        continue outer
                    }
                }
            }
            if config.soundAlike, let change = soundAlike(at: i, words: words, parts: parts, keys: keys) {
                out.append(change)
                i += change.count
                continue
            }
            i += 1
        }
        return out
    }

    /// "Opus5.5" → "Opus 5.5" when the prefix is a term (or a heard-as form of one) that the user
    /// writes apart from numbers. Identifiers ("base64", "MP4") are never split.
    func numberSplit(at i: Int, words: [TranscriptWord], parts: [(lead: String, core: String, trail: String)]) -> TermChange? {
        let core = parts[i].core
        guard let s = NumberSpacing.split(core), !NumberSpacing.identifiers.contains(core.lowercased()) else { return nil }
        let k = SoundKey.spelling(s.prefix)
        let ti: Int?
        if let t = byKey[k] {
            ti = t
        } else if let a = aliases[k], a.unconditional || a.count >= config.minAliasCount && !a.allCommon {
            ti = a.term
        } else {
            ti = nil
        }
        guard let ti, entries[ti].apartFromNumbers else { return nil }
        return TermChange(
            start: i, count: 1, original: core, replacement: entries[ti].spelling + " " + s.number, rule: .number,
            confidence: words[i].confidence, detail: "name and number glued")
    }

    func soundAlike(at i: Int, words: [TranscriptWord], parts: [(lead: String, core: String, trail: String)], keys: [String]) -> TermChange? {
        var best: (change: TermChange, score: Double)?
        for n in 1...min(2, words.count - i) {
            if n == 2, !parts[i].trail.isEmpty || !parts[i + 1].lead.isEmpty { continue }
            // "For realbird", "or Shiptiffen": a short function word is not part of the name, and a
            // word that is already a heard-as form is matched on its own at the next position.
            if n == 2, [i, i + 1].contains(where: { (parts[$0].core.count <= 3 && common.contains(parts[$0].core)) || aliases[keys[$0]] != nil }) { continue }
            let span = i..<(i + n)
            let conf = span.map { words[$0].confidence }.min() ?? 1
            guard conf < config.confidence else { continue }
            let original = span.map { parts[$0].core }.joined(separator: " ")
            let key = span.map { keys[$0] }.joined()
            guard key.count >= 4, byKey[key] == nil, !common.allCommon(original) else { continue }
            // Single words that are other known terms' pieces are left alone too.
            if span.contains(where: { byKey[keys[$0]] != nil }) { continue }
            // Nor their plurals and possessives ("TikToks", "Reddit's").
            if span.contains(where: { j in keys[j].hasSuffix("s") && keys[j].count > 3 && byKey[String(keys[j].dropLast())] != nil }) { continue }
            let sound = SoundKey.sound(original)
            for e in entries where !e.isCommonWord && e.key.count >= 5 {
                let s = SoundKey.similarity(sound, e.sound), p = SoundKey.similarity(key, e.key)
                guard s >= config.soundMin, p >= config.spellingMin else { continue }
                let score = s + p
                if best == nil || score > best!.score {
                    best = (TermChange(
                        start: i, count: n, original: original, replacement: e.spelling, rule: .sound, confidence: conf,
                        detail: String(format: "sounds %.2f, spelled %.2f, unsure %.2f", s, p, conf)), score)
                }
            }
        }
        return best?.change
    }

    /// Applies changes (from `propose` on the same words). Text is rebuilt from the words when
    /// anything changed; tokens stay the recogniser's own.
    public static func apply(_ changes: [TermChange], to transcript: Transcript) -> Transcript {
        guard !changes.isEmpty else { return transcript }
        var words: [TranscriptWord] = []
        var i = 0
        let byStart = Dictionary(changes.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        let source = transcript.words
        while i < source.count {
            if let c = byStart[i], c.count > 0, i + c.count <= source.count {
                let first = split(source[i].text), last = split(source[i + c.count - 1].text)
                let span = source[i..<(i + c.count)]
                words.append(TranscriptWord(
                    text: first.lead + c.replacement + last.trail, start: span.first!.start, end: span.last!.end,
                    confidence: span.map(\.confidence).min() ?? 1))
                i += c.count
            } else {
                words.append(source[i])
                i += 1
            }
        }
        return Transcript(text: words.map(\.text).joined(separator: " "), words: words, tokens: transcript.tokens)
    }
}
