import Foundation

/// The rules that keep the dictionary small and clean.
public struct VocabularyRules: Sendable, Equatable {
    /// Most live terms at once. Boosting many common-looking terms hurt accuracy in the October
    /// bench, and FluidAudio's thresholds are tuned for vocabularies around this size.
    public var cap = 300
    /// Sightings before an untrusted (history or correction) term goes live.
    public var liveAfterSightings = 2
    /// A term not seen for this long retires (manual terms never do).
    public var retireAfterDays: Double = 30
    /// Two spellings with the same sound key merge only if their spellings are at least this alike.
    public var soundMergeMinSpelling = 0.7

    public init() {}
}

/// The dictionary as a value: every rule is a pure function of the terms and the observations
/// fed in, so the same inputs always give the same book. `VocabularyStore` persists it.
public struct VocabularyBook: Sendable, Equatable {
    public private(set) var terms: [VocabularyTerm]
    public var rules: VocabularyRules

    public enum Outcome: Sendable, Equatable {
        case added
        case merged(into: String)
        /// The observed spelling became a heard-as form of an existing term, or the reverse.
        case aliased(into: String)
        case rejected(String)
    }

    public init(terms: [VocabularyTerm] = [], rules: VocabularyRules = VocabularyRules()) {
        self.terms = terms.sorted { $0.key < $1.key }
        self.rules = rules
    }

    public var live: [VocabularyTerm] { terms.filter { $0.state == .live } }

    public func term(_ spellingOrKey: String) -> VocabularyTerm? {
        let key = SoundKey.spelling(spellingOrKey)
        return terms.first { $0.key == key }
    }

    // MARK: - Junk rules

    /// Rules on the spelling alone.
    public static func junkReason(spelling: String) -> String? {
        let key = SoundKey.spelling(spelling)
        if key.count < 2 { return "too short" }
        if spelling.contains("@") || spelling.contains("://") || spelling.contains("www.") { return "an address, not a spoken term" }
        if spelling.split(whereSeparator: \.isWhitespace).count > 3 { return "a phrase, not a term" }
        if key.allSatisfy(\.isNumber) { return "a number" }
        return nil
    }

    /// Rules for a learned replacement ("the user changed `heard` into `spelling`"), such as
    /// Wispr's auto-learned dictionary. Nil when it looks like a real correction.
    public func learnedJunkReason(spelling: String, heard: String) -> String? {
        if let r = Self.junkReason(spelling: spelling) { return r }
        let key = SoundKey.spelling(spelling), heardKey = SoundKey.spelling(heard)
        guard !heardKey.isEmpty else { return nil }
        if key.hasPrefix(heardKey), key.count > heardKey.count + 2 { return "the edit appended text to \"\(heard)\"" }
        let like = SoundKey.likeness(spelling, heard)
        if like.sound < 0.34, like.spelling < 0.34 { return "\"\(heard)\" does not sound like it" }
        // Rewriting another known term is junk ("invideo" learned from "NVIDIA"), unless the two
        // are spelled nearly alike and the heard one is only a past mishearing ("Umami" from "Omami").
        if let other = terms.first(where: { $0.key == heardKey && $0.key != key && $0.state != .blocked }),
            other.bestSource.isTrusted || SoundKey.similarity(key, heardKey) < 0.7
        {
            return "it would rewrite the known term \(other.spelling)"
        }
        return nil
    }

    // MARK: - Adding evidence

    /// Adds one observation. Same spelling key: merged. Same sound and alike spelling: one becomes
    /// a heard-as form of the other (the more trusted source keeps the spelling). Otherwise added
    /// as a candidate. Heard-as forms that are themselves known terms are dropped.
    @discardableResult
    public mutating func observe(_ o: TermObservation) -> Outcome {
        if let reason = Self.junkReason(spelling: o.spelling) { return .rejected(reason) }
        let key = SoundKey.spelling(o.spelling)
        if let i = terms.firstIndex(where: { $0.key == key }) {
            if terms[i].state == .blocked { return .rejected("blocked: \(terms[i].note ?? "")") }
            if o.source.rank < terms[i].bestSource.rank { terms[i].spelling = o.spelling }
            absorb(o, into: i)
            return .merged(into: terms[i].spelling)
        }
        let sound = SoundKey.sound(o.spelling)
        // Two spellings seen only in past dictations ("Astra", "Astro") may both be real: they
        // merge by sound only when one side comes from a trusted source.
        if sound.count >= 2, !o.isCommonWord,
            let i = terms.firstIndex(where: {
                $0.state != .blocked && !$0.isCommonWord && $0.sound == sound && (o.source.isTrusted || $0.bestSource.isTrusted)
                    && SoundKey.similarity($0.key, key) >= rules.soundMergeMinSpelling
            })
        {
            let existing = terms[i]
            let newWins = o.source.rank < existing.bestSource.rank
                || (o.source.rank == existing.bestSource.rank && o.count > existing.sightings)
            if newWins {
                var t = VocabularyTerm(
                    spelling: o.spelling, aliases: existing.aliases.filter { $0.key != key }, sources: existing.sources, projects: existing.projects,
                    sightings: existing.sightings, firstSeen: existing.firstSeen, lastSeen: existing.lastSeen,
                    state: existing.state, isCommonWord: o.isCommonWord)
                Self.addAlias(&t, HeardAs(form: existing.spelling, count: existing.sightings, source: existing.bestSource))
                terms[i] = t
                absorb(o, into: i)
                resort()
                return .aliased(into: o.spelling)
            }
            var heard = o
            heard.heardAs[o.spelling, default: 0] += o.count
            absorb(heard, into: i)
            return .aliased(into: existing.spelling)
        }
        var t = VocabularyTerm(
            spelling: o.spelling, sources: [], sightings: 0, firstSeen: o.at, lastSeen: o.at, isCommonWord: o.isCommonWord)
        t.firstSeen = o.at
        terms.append(t)
        resort()
        absorb(o, into: terms.firstIndex { $0.key == key }!)
        return .added
    }

    /// A learned replacement: blocked with a reason if a junk rule fires, else observed with
    /// `heard` as a heard-as form.
    @discardableResult
    ///
    /// Junk from a dictionary (`block: true`, Wispr's learned entries) is blocked so a re-import
    /// never brings it back, unless the spelling is already a term from other evidence; junk from
    /// one-off edits is only dropped.
    public mutating func observeLearned(spelling: String, heard: String, source: TermSource, count: Int, at: Date, block shouldBlock: Bool = true) -> Outcome {
        if let reason = learnedJunkReason(spelling: spelling, heard: heard) {
            if shouldBlock, term(spelling) == nil { block(spelling: spelling, reason: "\(reason) (learned from \"\(heard)\")", at: at) }
            return .rejected(reason)
        }
        let heardKey = SoundKey.spelling(heard)
        let outcome = observe(TermObservation(spelling: spelling, source: source, heardAs: [heard: count], count: count, at: at))
        // A past mishearing that became its own term ("Omami") folds into the corrected one.
        if let h = term(heardKey), h.sources == [.history], let me = term(spelling), h.key != me.key {
            fold(h.key, into: me.key)
        }
        return outcome
    }

    /// Marks a spelling as junk for good.
    public mutating func block(spelling: String, reason: String, at: Date) {
        let key = SoundKey.spelling(spelling)
        guard !key.isEmpty else { return }
        if let i = terms.firstIndex(where: { $0.key == key }) {
            terms[i].state = .blocked
            terms[i].note = reason
        } else {
            terms.append(VocabularyTerm(spelling: spelling, sources: [], sightings: 0, firstSeen: at, lastSeen: at, state: .blocked, note: reason))
            resort()
        }
    }

    /// Turns term `key` into a heard-as form of term `into` (its sightings move too). Used when a
    /// spelling seen only in past dictations ("Shiftify") is a mishearing of a trusted term
    /// ("ShipTiffin").
    public mutating func fold(_ key: String, into target: String) {
        guard key != target, let i = terms.firstIndex(where: { $0.key == key }), let j = terms.firstIndex(where: { $0.key == target }) else { return }
        let old = terms[i]
        Self.addAlias(&terms[j], HeardAs(form: old.spelling, count: max(1, old.sightings), source: old.bestSource))
        for a in old.aliases { Self.addAlias(&terms[j], a) }
        terms[j].sightings += old.sightings
        terms[j].lastSeen = max(terms[j].lastSeen, old.lastSeen)
        for p in old.projects where !terms[j].projects.contains(p) { terms[j].projects.append(p) }
        terms[j].projects.sort()
        terms.remove(at: i)
    }

    /// Folds history-only spellings into a trusted term they sound and look like ("Shiftifin" →
    /// ShipTiffin). A spelling is not folded when a closer history-only spelling does not itself
    /// match that trusted term: "Headsner" sounds like Eisner (trusted) but is closer to Hetzner,
    /// which does not, so it stays near Hetzner. Returns the folds.
    @discardableResult
    public mutating func foldMishearings(soundMin: Double = 0.7, spellingMin: Double = 0.6) -> [(from: String, into: String)] {
        func like(_ a: VocabularyTerm, _ b: VocabularyTerm) -> Double? {
            let s = SoundKey.similarity(a.sound, b.sound), p = SoundKey.similarity(a.key, b.key)
            return s >= soundMin && p >= spellingMin ? s + p : nil
        }
        let eligible = terms.filter { $0.state != .blocked && !$0.isCommonWord && $0.key.count >= 5 }
        let trusted = eligible.filter { $0.bestSource.isTrusted }
        let historyOnly = eligible.filter { $0.sources == [.history] }
        var folds: [(String, String)] = []
        for t in historyOnly {
            guard let (target, score) = trusted.compactMap({ T in like(t, T).map { (T, $0) } }).max(by: { $0.1 < $1.1 }) else { continue }
            let closer = historyOnly.filter { n in n.key != t.key && (like(t, n) ?? 0) > score }
            if closer.allSatisfy({ like($0, target) != nil }) { folds.append((t.spelling, target.spelling)) }
        }
        for (from, into) in folds { fold(SoundKey.spelling(from), into: SoundKey.spelling(into)) }
        return folds
    }

    /// Records how the user writes each term next to a number ("Opus 4.5" apart, "Opus4.5" joined),
    /// from `NumberSpacing.count` over his past writing.
    public mutating func recordNumberSpacing(apart: [String: Int], joined: [String: Int]) {
        for i in terms.indices {
            let a = apart[terms[i].key], j = joined[terms[i].key]
            guard a != nil || j != nil else { continue }
            terms[i].numberApart = a ?? 0
            terms[i].numberJoined = j ?? 0
        }
    }

    /// Keeps what a rebuild must not lose from an older book: manual terms and blocked spellings.
    public mutating func carryOver(from old: VocabularyBook) {
        for t in old.terms where t.state == .blocked || t.sources.contains(.manual) {
            if let i = terms.firstIndex(where: { $0.key == t.key }) {
                if t.state == .blocked { terms[i].state = .blocked; terms[i].note = t.note }
            } else {
                terms.append(t)
            }
        }
        resort()
    }

    private mutating func absorb(_ o: TermObservation, into i: Int) {
        terms[i].sightings += o.count
        if !terms[i].sources.contains(o.source) {
            terms[i].sources.append(o.source)
            terms[i].sources.sort { $0.rank < $1.rank }
        }
        terms[i].firstSeen = min(terms[i].firstSeen, o.at)
        terms[i].lastSeen = max(terms[i].lastSeen, o.at)
        for p in o.projects.map({ $0.lowercased() }) where !terms[i].projects.contains(p) { terms[i].projects.append(p) }
        terms[i].projects.sort()
        let ownKey = terms[i].key
        for (form, n) in o.heardAs.sorted(by: { $0.key < $1.key }) {
            let k = SoundKey.spelling(form)
            guard !k.isEmpty, k != ownKey else { continue }
            // Never turn one known term into another.
            if terms.contains(where: { $0.key == k && $0.state != .blocked }) { continue }
            Self.addAlias(&terms[i], HeardAs(form: form, count: n, source: o.source))
        }
    }

    /// "databases" for "database", "stories" for "story": another form of the word, not a mishearing.
    public static func isInflection(_ a: String, _ b: String) -> Bool {
        let (s, l) = a.count <= b.count ? (a, b) : (b, a)
        guard s.count >= 3 else { return false }
        for suffix in ["s", "es", "ed", "d", "ing", "er", "ers", "ly"] where l == s + suffix { return true }
        if s.hasSuffix("y"), l == s.dropLast() + "ies" || l == s.dropLast() + "ied" { return true }
        if s.hasSuffix("e"), l == s.dropLast() + "ing" { return true }
        return false
    }

    private static func addAlias(_ t: inout VocabularyTerm, _ a: HeardAs) {
        guard a.key != t.key, !a.key.isEmpty, !isInflection(a.key, t.key) else { return }
        if let j = t.aliases.firstIndex(where: { $0.key == a.key }) {
            t.aliases[j].count += a.count
            if a.source.rank < t.aliases[j].source.rank { t.aliases[j].source = a.source }
        } else {
            t.aliases.append(a)
        }
        t.aliases.sort { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
    }

    private mutating func resort() { terms.sort { $0.key < $1.key } }

    // MARK: - Live set

    /// Ranking used by the cap: trusted sources first, then how often and how recently it was said.
    public static func score(_ t: VocabularyTerm, now: Date) -> Double {
        let trust = Double(5 - t.bestSource.rank) * 2
        let often = log2(1 + Double(t.sightings))
        let days = max(0, now.timeIntervalSince(t.lastSeen) / 86_400)
        return trust + often + (days < 7 ? 1 : 0)
    }

    /// Sets each term's state: live (trusted source or enough sightings), candidate, or retired
    /// (unseen for `retireAfterDays`, or below the cap). Blocked terms stay blocked.
    public mutating func refresh(now: Date) {
        let retireBefore = now.addingTimeInterval(-rules.retireAfterDays * 86_400)
        for i in terms.indices where terms[i].state != .blocked {
            let t = terms[i]
            if !t.sources.contains(.manual), t.lastSeen < retireBefore {
                terms[i].state = .retired
                terms[i].note = "not seen for \(Int(rules.retireAfterDays)) days"
            } else if t.sources.contains(where: \.isTrusted) || t.sightings >= rules.liveAfterSightings {
                terms[i].state = .live
                terms[i].note = nil
            } else {
                terms[i].state = .candidate
                terms[i].note = nil
            }
        }
        let ranked = terms.indices.filter { terms[$0].state == .live }
            .sorted { a, b in
                let sa = Self.score(terms[a], now: now), sb = Self.score(terms[b], now: now)
                return sa != sb ? sa > sb : terms[a].key < terms[b].key
            }
        for i in ranked.dropFirst(rules.cap) {
            terms[i].state = .retired
            terms[i].note = "over the \(rules.cap)-term cap"
        }
    }
}
