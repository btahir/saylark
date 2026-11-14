import Foundation
import Testing
@testable import SaylarkCore

@Suite struct HeardAsLearnerTests {
    static let at = Date(timeIntervalSince1970: 1_800_000_000)
    static let common = CommonWords(["the", "we", "use", "for", "a", "cloud", "code", "fall", "back", "level", "labs", "and", "it", "is", "on", "web", "new", "today", "ship"])

    static func term(_ spelling: String, aliases: [String: Int] = [:]) -> VocabularyTerm {
        VocabularyTerm(
            spelling: spelling, aliases: aliases.map { HeardAs(form: $0.key, count: $0.value, source: .history) },
            sources: [.project], sightings: 5, firstSeen: at, lastSeen: at, state: .live)
    }

    static let terms = [term("Codex"), term("ElevenLabs"), term("Claude"), term("Fal")]

    @Test func alignsSingleWordsAndPhrases() {
        let p = HeardAsLearner.pairs(heard: "we use codecs for the level labs voice", reference: "We use Codex for the ElevenLabs voice.", terms: Self.terms)
        #expect(p.map(\.formKey) == ["codecs", "level labs"])
        #expect(p.map(\.termSpelling) == ["Codex", "ElevenLabs"])
    }

    @Test func wordsGluedToNumbersAreNotPairs() {
        #expect(HeardAsLearner.pairs(heard: "try Opus5.5 now", reference: "Try Opus 5.5 now", terms: [Self.term("Opus")]).isEmpty)
    }

    @Test func spacingOnlyAndCorrectWordsAreNotPairs() {
        #expect(HeardAsLearner.pairs(heard: "we use Codex with Eleven Labs", reference: "We use Codex with ElevenLabs", terms: Self.terms).isEmpty)
    }

    @Test func fillersAndEdgeWordsAreNotPartOfTheForm() {
        let p = HeardAsLearner.pairs(heard: "try a level labs uh voice", reference: "Try ElevenLabs voice", terms: Self.terms)
        #expect(p.map(\.formKey) == ["level labs"])
    }

    @Test func goesLiveAfterEnoughConsistentSightings() {
        var l = HeardAsLearner()
        l.learn(heard: "we use codecs today", reference: "We use Codex today", terms: Self.terms, common: Self.common, at: Self.at)
        #expect(l.live.isEmpty)  // one hit is not enough
        let changed = l.learn(heard: "codecs is fast", reference: "Codex is fast", terms: Self.terms, common: Self.common, at: Self.at)
        #expect(changed.map(\.state) == [.live])
        #expect(l.live.first?.form == "codecs")
        #expect(l.live.first?.precision == 1)
    }

    @Test func isRetiredWhenPrecisionDrops() {
        var l = HeardAsLearner()
        for _ in 0..<2 { l.learn(heard: "we use codecs", reference: "We use Codex", terms: Self.terms, common: Self.common, at: Self.at) }
        #expect(l.live.count == 1)
        // He now says "codecs" and means codecs: the recogniser writes it, the reference agrees.
        var retired: [HeardAsLearner.Candidate] = []
        for _ in 0..<2 { retired += l.learn(heard: "web codecs are new", reference: "Web codecs are new", terms: Self.terms, common: Self.common, at: Self.at) }
        #expect(retired.map(\.state) == [.retired])
        #expect(l.live.isEmpty)
        #expect(l.all.first?.hits == 2 && l.all.first?.seen == 4)
    }

    @Test func ordinaryWordNeedsStrongerEvidence() {
        var l = HeardAsLearner()
        // "cloud" meant Claude twice: enough for a rare form, not for an ordinary word.
        for _ in 0..<2 { l.learn(heard: "ask cloud", reference: "Ask Claude", terms: Self.terms, common: Self.common, at: Self.at) }
        #expect(l.live.isEmpty)
        l.learn(heard: "ask cloud", reference: "Ask Claude", terms: Self.terms, common: Self.common, at: Self.at)
        #expect(l.live.map(\.form) == ["cloud"])
        // Once he says "cloud" literally, precision falls below the ordinary-word bar... and the
        // retire bar, so it goes.
        for _ in 0..<3 { l.learn(heard: "the cloud bill", reference: "The cloud bill", terms: Self.terms, common: Self.common, at: Self.at) }
        #expect(l.live.isEmpty)
    }

    @Test func pastWritingVetoesAFormHeMeansLiterally() {
        var l = HeardAsLearner()
        l.learnAll([
            (heard: "fall is fast", reference: "Fal is fast", at: Self.at),
            (heard: "use fall today", reference: "Use Fal today", at: Self.at),
            (heard: "fall back", reference: "Fal back", at: Self.at),
        ], terms: Self.terms, common: Self.common)
        #expect(l.live.map(\.form) == ["fall"])  // 3 of 3 in these takes
        l.noteWriting(["we fall back", "prices fall", "in the fall", "Fal is cheap"])
        l.refreshStates()
        #expect(l.live.isEmpty)
        #expect(l.all.first?.state == .retired)
    }

    @Test func liveFormsBecomeAsrAliases() {
        var l = HeardAsLearner()
        for _ in 0..<2 { l.learn(heard: "we use codecs", reference: "We use Codex", terms: Self.terms, common: Self.common, at: Self.at) }
        let terms = l.applying(to: Self.terms)
        let codex = terms.first { $0.spelling == "Codex" }!
        #expect(codex.aliases.map(\.form) == ["codecs"])
        #expect(codex.aliases.first?.source == .asr && codex.aliases.first?.seen == 2)
        // And the swapper uses it even when the recogniser was sure.
        let w = "we use codecs".split(separator: " ").enumerated().map { TranscriptWord(text: String($1), start: Double($0), end: Double($0) + 0.5, confidence: 0.99) }
        let swapper = TermSwapper(terms: terms, common: Self.common)
        #expect(TermSwapper.apply(swapper.propose(w), to: Transcript(text: "we use codecs", words: w)).text == "we use Codex")
        var off = TermSwapper.Config()
        off.learnedAliases = false
        #expect(TermSwapper(terms: terms, common: Self.common, config: off).propose(w).isEmpty)
    }
}

@Suite struct NumberSpacingTests {
    static let at = Date(timeIntervalSince1970: 1_800_000_000)

    static func term(_ spelling: String, apart: Int, joined: Int = 0) -> VocabularyTerm {
        var t = VocabularyTerm(spelling: spelling, sources: [.history], sightings: 5, firstSeen: at, lastSeen: at, state: .live)
        t.numberApart = apart
        t.numberJoined = joined
        return t
    }

    static func run(_ text: String, terms: [VocabularyTerm]) -> String {
        let w = text.split(separator: " ").enumerated().map { TranscriptWord(text: String($1), start: Double($0), end: Double($0) + 0.5, confidence: 0.99) }
        let swapper = TermSwapper(terms: terms, common: CommonWords(["use", "with", "and", "the", "or"]))
        return TermSwapper.apply(swapper.propose(w), to: Transcript(text: text, words: w)).text
    }

    @Test func splitsTermsWrittenApart() {
        let terms = [Self.term("Opus", apart: 12), Self.term("Sonnet", apart: 4), Self.term("Lyria", apart: 2)]
        #expect(Self.run("use Opus5.5 and sonnet4.5, or Lyria3.", terms: terms) == "use Opus 5.5 and Sonnet 4.5, or Lyria 3.")
    }

    @Test func identifiersAreUntouched() {
        // Terms the user writes glued (GPT4, H3) or never next to numbers stay as they are; known
        // identifiers are never split even if their prefix were a term.
        let terms = [Self.term("GPT", apart: 1, joined: 5), Self.term("V", apart: 0), Self.term("H", apart: 0), Self.term("Base", apart: 3), Self.term("SHA", apart: 2)]
        let text = "use base64 with sha256 and utf8 or MP4 and H3 and V4 and R2 and GPT4"
        #expect(Self.run(text, terms: terms) == text)
    }

    @Test func termsWithoutEvidenceAreNotSplit() {
        #expect(Self.run("use Opus5.5", terms: [Self.term("Opus", apart: 0)]) == "use Opus5.5")
    }

    @Test func countsApartAndJoinedInWriting() {
        let c = NumberSpacing.count(in: "Opus 4.5 beats Opus4 and GPT4, Sonnet 4.5. base64", keys: ["opus", "gpt", "sonnet", "base"])
        #expect(c.apart == ["opus": 1, "sonnet": 1])
        #expect(c.joined == ["opus": 1, "gpt": 1])
    }

    @Test func parsesOnlyLettersThenNumber() {
        #expect(NumberSpacing.split("Opus5.5")?.prefix == "Opus")
        #expect(NumberSpacing.split("Opus5.5")?.number == "5.5")
        #expect(NumberSpacing.split("5.5") == nil)
        #expect(NumberSpacing.split("v1.") == nil)
        #expect(NumberSpacing.split("x2y") == nil)
    }
}
