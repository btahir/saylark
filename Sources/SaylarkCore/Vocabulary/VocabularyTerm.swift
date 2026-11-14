import Foundation

/// Where evidence for a term came from. Lower `rank` is more trusted: when two spellings that
/// sound alike merge, the more trusted one becomes the term and the other a heard-as form.
public enum TermSource: String, Codable, Sendable, CaseIterable {
    /// Typed in by the user.
    case manual
    /// A project folder, package or README name, or a Claude/Codex session's working folder.
    case project
    /// Wispr Flow's dictionary (manual entries, or auto-learned entries that passed the junk rules).
    case wisprDictionary
    /// A correction: the user's edited or sent text disagreed with the recogniser on this word.
    case correction
    /// Said in past dictations often enough (rare word, two or more sightings).
    case history
    /// Seen on screen or in the agent's reply for one take. Never live on its own.
    case context
    /// Saylark's own recogniser wrote this form where a reference (Wispr's text for the same take,
    /// or an answer key) had the term, often enough and consistently enough (`HeardAsLearner`).
    case asr

    public var rank: Int {
        switch self {
        case .manual: 0
        case .project: 1
        case .wisprDictionary: 2
        case .correction: 3
        case .history: 4
        case .context: 5
        case .asr: 3
        }
    }

    /// Trusted sources make a term live on the first sighting.
    public var isTrusted: Bool { rank <= 2 }
}

/// A form the recogniser (or Wispr) wrote when the user said the term: "UTLDR" for "YouTLDR",
/// "real bird" for "Reelbird".
public struct HeardAs: Codable, Sendable, Equatable {
    public var form: String
    public var key: String
    public var count: Int
    public var source: TermSource
    /// For `.asr` forms: how often the recogniser wrote this form at all; `count / seen` is the
    /// share of times it meant the term.
    public var seen: Int?

    public init(form: String, count: Int, source: TermSource, seen: Int? = nil) {
        self.form = form
        self.key = SoundKey.spelling(form)
        self.count = count
        self.source = source
        self.seen = seen
    }
}

/// One dictionary term.
public struct VocabularyTerm: Codable, Sendable, Equatable, Identifiable {
    public enum State: String, Codable, Sendable {
        /// Seen, not yet trusted (one sighting from history).
        case candidate
        /// Used for correction.
        case live
        /// Not seen for `retireAfterDays`, or pushed out by the cap. Comes back when seen again.
        case retired
        /// Rejected by a junk rule; never comes back. `note` says why.
        case blocked
    }

    public var spelling: String
    public var key: String
    public var sound: String
    public var aliases: [HeardAs]
    public var sources: [TermSource]
    /// Project folders the term belongs to or was said in (folder names, lowercased).
    public var projects: [String]
    public var sightings: Int
    public var firstSeen: Date
    public var lastSeen: Date
    public var state: State
    public var note: String?
    /// The spelling is an ordinary word ("Dibs", "Fable"): never the target of a sound-alike swap.
    public var isCommonWord: Bool
    /// In past dictations, how often a number followed the term with a space ("Opus 4.5") and
    /// glued to it ("Opus4.5"). Decides whether "Opus5.5" from the recogniser is split.
    public var numberApart: Int?
    public var numberJoined: Int?

    /// Written apart from a following number often enough that a glued form is a recogniser defect.
    public var isWrittenApartFromNumbers: Bool { (numberApart ?? 0) >= 1 && (numberApart ?? 0) > (numberJoined ?? 0) }

    public var id: String { key }
    public var bestSource: TermSource { sources.min { $0.rank < $1.rank } ?? .history }

    public init(
        spelling: String, aliases: [HeardAs] = [], sources: [TermSource], projects: [String] = [], sightings: Int,
        firstSeen: Date, lastSeen: Date, state: State = .candidate, note: String? = nil, isCommonWord: Bool = false
    ) {
        self.spelling = spelling
        self.key = SoundKey.spelling(spelling)
        self.sound = SoundKey.sound(spelling)
        self.aliases = aliases
        self.sources = sources
        self.projects = projects
        self.sightings = sightings
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.state = state
        self.note = note
        self.isCommonWord = isCommonWord
    }
}

/// One piece of evidence for a term, from any source.
public struct TermObservation: Sendable, Equatable {
    public var spelling: String
    public var source: TermSource
    /// Forms it was heard as, with counts.
    public var heardAs: [String: Int]
    public var projects: [String]
    public var count: Int
    public var at: Date
    public var isCommonWord: Bool

    public init(spelling: String, source: TermSource, heardAs: [String: Int] = [:], projects: [String] = [], count: Int = 1, at: Date, isCommonWord: Bool = false) {
        self.spelling = spelling
        self.source = source
        self.heardAs = heardAs
        self.projects = projects
        self.count = count
        self.at = at
        self.isCommonWord = isCommonWord
    }
}
