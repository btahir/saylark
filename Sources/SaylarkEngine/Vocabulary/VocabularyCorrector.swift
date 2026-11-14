import FluidAudio
import Foundation
import SaylarkCore

/// Fixes names and jargon in one transcription window. Safe to call per window from the
/// streaming transcriber, concurrently: all state is immutable or behind a lock.
///
/// Two steps, each optional (`Config.mode`):
/// - **ctc**: FluidAudio's CTC keyword spotter (parakeet-ctc-110m, a second, small model) scores
///   the window's audio, and its rescorer proposes terms where the acoustic evidence prefers them.
///   Saylark applies a proposal only if it passes `ctcGuard` (ordinary words the recogniser was
///   sure of are never rewritten unless they are a known heard-as form).
/// - **swap**: `TermSwapper`, text only: known heard-as forms, spacing, unsure sound-alikes.
///
/// Usage (per closed window, audio and tokens on the same clock):
/// ```swift
/// let fixed = await corrector.correct(window.transcript, samples: windowSamples,
///                                     timeOffset: windowStartSeconds, context: context)
/// ```
public final class VocabularyCorrector: Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case off, ctc, swap, both
        var usesCTC: Bool { self == .ctc || self == .both }
        var usesSwap: Bool { self == .swap || self == .both }
    }

    public struct Config: Codable, Sendable, Equatable {
        public var mode: Mode = .swap
        /// Terms used per take, picked by `TermRanker` (global score plus context).
        public var termLimit = 300
        public var swap = SwapConfig()
        /// FluidAudio rescorer: minimum string similarity (it also applies its own size-based floor).
        public var ctcMinSimilarity: Float = 0.6
        /// Context-biasing weight added to a term's CTC score.
        public var ctcCbw: Float = 4.5
        /// FluidAudio's acoustic-only "spotter rescue" (the main source of over-firing in its notes).
        public var ctcSpotterRescue = false
        /// Veto CTC proposals that rewrite ordinary words the recogniser was sure of.
        public var ctcGuard = true
        /// "Sure" for the guard.
        public var ctcGuardConfidence: Float = 0.6

        public init() {}
    }

    /// `TermSwapper.Config` as a codable value.
    public struct SwapConfig: Codable, Sendable, Equatable {
        public var confidence: Float = 0.6
        public var minAliasCount = 2
        public var soundMin = 0.8
        public var spellingMin = 0.6
        public var soundAlike = true
        /// Heard-as forms learned from Saylark's own recogniser (precision-gated).
        public var learnedAliases = true
        /// "Opus5.5" → "Opus 5.5" for terms written apart from numbers.
        public var splitNumbers = true
        public init() {}

        var swapper: TermSwapper.Config {
            var c = TermSwapper.Config()
            c.confidence = confidence
            c.minAliasCount = minAliasCount
            c.soundMin = soundMin
            c.spellingMin = spellingMin
            c.soundAlike = soundAlike
            c.learnedAliases = learnedAliases
            c.splitNumbers = splitNumbers
            return c
        }
    }

    /// The corrected window and what changed.
    public struct Correction: Sendable {
        public var transcript: Transcript
        public var changes: [TermChange]
        /// CTC rescorer proposals that the guard vetoed (for `--explain` and the learning loop).
        public var vetoed: [TermChange]
        /// Terms the CTC spotter found in the audio (evidence even when nothing changed).
        public var detected: [String]
        public var ctcMs: Double
        public var swapMs: Double
        public var termsUsed: Int
    }

    public let config: Config
    public let terms: [VocabularyTerm]
    let common: CommonWords
    let ctc: CTCScorer?

    /// `terms` are the live terms (from `VocabularyStore.liveTerms()`). Loads the CTC model only
    /// when the mode needs it (about 0.1 s, models already downloaded).
    public static func load(terms: [VocabularyTerm], common: CommonWords, config: Config = Config()) async throws -> VocabularyCorrector {
        let ctc = config.mode.usesCTC ? try await CTCScorer.load() : nil
        return VocabularyCorrector(terms: terms, common: common, config: config, ctc: ctc)
    }

    init(terms: [VocabularyTerm], common: CommonWords, config: Config, ctc: CTCScorer?) {
        self.terms = terms.filter { $0.state == .live }
        self.common = common
        self.config = config
        self.ctc = ctc
    }

    /// A corrector sharing this one's CTC model with a different config (evals, settings changes).
    public func with(config: Config) async throws -> VocabularyCorrector {
        var scorer = ctc
        if config.mode.usesCTC, scorer == nil { scorer = try await CTCScorer.load() }
        return VocabularyCorrector(terms: terms, common: common, config: config, ctc: scorer)
    }

    /// Corrects one window. `samples` is the window's audio; `timeOffset` is where it starts in the
    /// take (the transcript's times are take times, as `Recognizer.transcribe(timeOffset:)` gives).
    /// Never throws: on any CTC failure the window comes back with only the text-level fixes.
    public func correct(
        _ transcript: Transcript, samples: [Float], timeOffset: Double = 0, context: VocabularyContext = .none, now: Date = Date(),
        evidence: AcousticEvidence? = nil
    ) async -> Correction {
        var out = Correction(transcript: transcript, changes: [], vetoed: [], detected: [], ctcMs: 0, swapMs: 0, termsUsed: 0)
        guard config.mode != .off, !transcript.words.isEmpty else { return out }
        let chosen = TermRanker.select(terms, context: context, limit: config.termLimit, now: now)
        out.termsUsed = chosen.count
        guard !chosen.isEmpty else { return out }
        if config.mode.usesCTC, let ctc {
            let began = ContinuousClock.now
            var lp = evidence?.logProbs
            if lp == nil { lp = try? await ctc.logProbs(samples) }
            if let lp {
                let r = await ctc.propose(transcript: transcript, timeOffset: timeOffset, logProbs: lp, terms: chosen, config: config)
                let (keep, veto) = guardCTC(r.changes, words: transcript.words, terms: chosen)
                out.transcript = TermSwapper.apply(keep, to: transcript)
                out.changes += keep
                out.vetoed = veto
                out.detected = r.detected
            }
            out.ctcMs = began.duration(to: .now).milliseconds
        }
        if config.mode.usesSwap {
            let began = ContinuousClock.now
            let swapper = TermSwapper(terms: chosen, common: common, config: config.swap.swapper)
            let changes = swapper.propose(out.transcript.words)
            out.transcript = TermSwapper.apply(changes, to: out.transcript)
            out.changes += changes
            out.swapMs = began.duration(to: .now).milliseconds
        }
        return out
    }

    /// The CTC model's output for a window, computed once and reusable across `correct` calls
    /// with different configs (evals). Nil when the mode has no CTC step or inference failed.
    public struct AcousticEvidence: Sendable {
        let logProbs: CTCScorer.LogProbs
        /// Time the CTC encoder took.
        public let ms: Double
    }

    public func acousticEvidence(_ samples: [Float]) async -> AcousticEvidence? {
        guard let ctc else { return nil }
        let began = ContinuousClock.now
        guard let lp = try? await ctc.logProbs(samples) else { return nil }
        return AcousticEvidence(logProbs: lp, ms: began.duration(to: .now).milliseconds)
    }

    /// Convenience for a whole `Recognition` (its own audio, starting at 0).
    public func correct(_ recognition: Recognition, samples: [Float], context: VocabularyContext = .none) async -> Correction {
        await correct(recognition.transcript, samples: samples, timeOffset: 0, context: context)
    }

    /// Splits CTC proposals into kept and vetoed. Vetoed: the replaced words are all ordinary
    /// English, the recogniser was sure of them, and they are not a heard-as form of the term;
    /// or the replaced words are themselves another known term.
    func guardCTC(_ changes: [TermChange], words: [TranscriptWord], terms: [VocabularyTerm]) -> (keep: [TermChange], veto: [TermChange]) {
        guard config.ctcGuard else { return (changes, []) }
        let byKey = Dictionary(terms.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var keep: [TermChange] = [], veto: [TermChange] = []
        for c in changes {
            let key = SoundKey.spelling(c.original)
            let term = byKey[SoundKey.spelling(c.replacement)]
            let isAlias = term?.aliases.contains { $0.key == key } ?? false
            if !isAlias, byKey[key] != nil, key != SoundKey.spelling(c.replacement) {
                var v = c; v.detail += "; vetoed: rewrites the known term \(c.original)"; veto.append(v); continue
            }
            // A single ordinary word ("use" -> "Muse", "loop" -> "Loom") is vetoed at any confidence:
            // the CTC rescorer favours the term too easily on short words.
            let single = !c.original.contains(" ")
            if !isAlias, common.allCommon(c.original), single || c.confidence >= config.ctcGuardConfidence {
                var v = c; v.detail += String(format: "; vetoed: ordinary words heard with confidence %.2f", c.confidence); veto.append(v); continue
            }
            keep.append(c)
        }
        return (keep, veto)
    }
}

/// The CTC keyword-spotting model and one FluidAudio rescorer per distinct term list (cached).
final class CTCScorer: Sendable {
    let models: CtcModels
    let spotter: CtcKeywordSpotter
    let tokenizer: CtcTokenizer
    let empty: CustomVocabularyContext
    private let cache = Locked<[String: (VocabularyRescorer, CustomVocabularyContext)]>([:])

    struct LogProbs: Sendable {
        let values: [[Float]]
        let frameDuration: Double
    }

    static func load() async throws -> CTCScorer {
        ModelPins.apply()
        let models = try await CtcModels.downloadAndLoad()
        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: models.variant))
        return CTCScorer(models: models, tokenizer: tokenizer)
    }

    init(models: CtcModels, tokenizer: CtcTokenizer) {
        self.models = models
        self.tokenizer = tokenizer
        spotter = CtcKeywordSpotter(models: models, blankId: models.vocabulary.count)
        empty = CustomVocabularyContext(terms: [])
    }

    /// One CTC encoder pass over the window (the expensive part).
    func logProbs(_ samples: [Float]) async throws -> LogProbs {
        let r = try await spotter.spotKeywordsWithLogProbs(audioSamples: samples, customVocabulary: empty, minScore: nil)
        return LogProbs(values: r.logProbs, frameDuration: r.frameDuration)
    }

    func rescorer(for terms: [VocabularyTerm], config: VocabularyCorrector.Config) async throws -> (VocabularyRescorer, CustomVocabularyContext) {
        let signature = "\(config.ctcSpotterRescue)|\(config.ctcMinSimilarity)|" + terms.map(\.key).joined(separator: ",")
        if let hit = cache.withLock({ $0[signature] }) { return hit }
        let vocabTerms = terms.compactMap { t -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(t.spelling)
            guard !ids.isEmpty else { return nil }
            let aliases = t.aliases.filter { $0.count >= 2 || $0.source.isTrusted }.map(\.form)
            return CustomVocabularyTerm(text: t.spelling, aliases: aliases.isEmpty ? nil : aliases, ctcTokenIds: ids)
        }
        let context = CustomVocabularyContext(terms: vocabTerms, minSimilarity: config.ctcMinSimilarity)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter, vocabulary: context,
            config: VocabularyRescorer.Config(spotterRescueEnabled: config.ctcSpotterRescue),
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: models.variant))
        cache.withLock { cache in
            if cache.count > 16 { cache.removeAll() }
            cache[signature] = (rescorer, context)
        }
        return (rescorer, context)
    }

    /// The rescorer's applied candidates, mapped onto the transcript's words. Proposals whose
    /// words cannot be matched exactly are dropped.
    func propose(transcript: Transcript, timeOffset: Double, logProbs lp: LogProbs, terms: [VocabularyTerm], config: VocabularyCorrector.Config) async -> (changes: [TermChange], detected: [String]) {
        guard !lp.values.isEmpty, !transcript.tokens.isEmpty else { return ([], []) }
        guard let (rescorer, context) = try? await rescorer(for: terms, config: config) else { return ([], []) }
        let timings = transcript.tokens.map {
            TokenTiming(token: $0.text, tokenId: $0.tokenId ?? 0, startTime: $0.start - timeOffset, endTime: $0.end - timeOffset, confidence: $0.confidence)
        }
        let minSimilarity = max(ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count).minSimilarity, context.minSimilarity)
        let evidence = rescorer.ctcTokenEvaluateCandidates(
            transcript: transcript.text, tokenTimings: timings, logProbs: lp.values, frameDuration: lp.frameDuration,
            cbw: config.ctcCbw, marginSeconds: 0.5, minSimilarity: minSimilarity)
        let words = transcript.words
        let base = evidence.baseWords
        let aligned = base.count == words.count
            && zip(base, words).allSatisfy { SoundKey.spelling($0) == SoundKey.spelling($1.text) }
        var changes: [TermChange] = []
        var used = IndexSet()
        for c in evidence.candidates where c.legacyOutcome == .applied {
            guard aligned, c.wordRange.upperBound <= words.count, !c.wordRange.isEmpty,
                !used.intersects(integersIn: c.wordRange)
            else { continue }
            used.insert(integersIn: c.wordRange)
            let span = words[c.wordRange]
            let original = span.map { TermSwapper.split($0.text).core }.joined(separator: " ")
            if original == c.canonicalTerm { continue }
            let detail = String(
                format: "%@, similarity %.2f, ctc term %.2f vs heard %.2f%@", c.origin.rawValue, c.similarity,
                c.rawVocabularyCTCScore ?? .nan, c.rawOriginalCTCScore ?? .nan, c.matchedAlias.map { ", via alias \($0)" } ?? "")
            changes.append(TermChange(
                start: c.wordRange.lowerBound, count: c.wordRange.count, original: original, replacement: c.canonicalTerm,
                rule: .ctc, confidence: span.map(\.confidence).min() ?? 1, detail: detail))
        }
        return (changes.sorted { $0.start < $1.start }, [])
    }
}
