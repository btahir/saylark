import Foundation
import Testing
@testable import SaylarkCore

@Suite struct SoundKeyTests {
    @Test func mishearingsShareASoundKey() {
        #expect(SoundKey.sound("UTLDR") == SoundKey.sound("YouTLDR"))
        #expect(SoundKey.sound("real bird") == SoundKey.sound("Reelbird"))
        #expect(SoundKey.sound("Realbird") == SoundKey.sound("Reelbird"))
        #expect(SoundKey.sound("superbase") == SoundKey.sound("Supabase"))
        #expect(SoundKey.sound("Omami") == SoundKey.sound("Umami"))
        #expect(SoundKey.sound("Shotcandy") != SoundKey.sound("Shipify"))
        #expect(SoundKey.similarity(SoundKey.sound("Shiftfn"), SoundKey.sound("ShipTiffin")) >= 0.7)
        #expect(SoundKey.similarity(SoundKey.sound("the GPU"), SoundKey.sound("nviidia")) < 0.34)
    }

    @Test func spellingKeyIgnoresCaseSpacingAndPunctuation() {
        #expect(SoundKey.spelling("Next.js") == "nextjs")
        #expect(SoundKey.spelling("Ship Tiffin") == SoundKey.spelling("ShipTiffin"))
    }

    @Test func commonWordsKnowInflections() {
        let common = CommonWords(["bird", "real", "deploy"])
        #expect(common.contains("birds"))
        #expect(common.contains("deployed"))
        #expect(common.allCommon("real bird"))
        #expect(!common.allCommon("real UTLDR"))
    }
}

@Suite struct VocabularyBookTests {
    static let day = Date(timeIntervalSince1970: 1_790_000_000)
    static func at(_ days: Double) -> Date { day.addingTimeInterval(days * 86_400) }

    @Test func sameSpellingMerges() {
        var book = VocabularyBook()
        #expect(book.observe(TermObservation(spelling: "Supabase", source: .history, count: 3, at: Self.at(0))) == .added)
        #expect(book.observe(TermObservation(spelling: "supabase", source: .history, count: 2, at: Self.at(1))) == .merged(into: "Supabase"))
        #expect(book.terms.count == 1)
        #expect(book.terms[0].sightings == 5)
        #expect(book.terms[0].lastSeen == Self.at(1))
    }

    @Test func trustedSourceSetsTheSpelling() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "youtldr", source: .history, count: 2, at: Self.at(0)))
        book.observe(TermObservation(spelling: "YouTLDR", source: .project, at: Self.at(0)))
        #expect(book.terms.map(\.spelling) == ["YouTLDR"])
    }

    @Test func soundAlikeSpellingsCollapseIntoTheTrustedTerm() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "UTLDR", source: .history, count: 32, at: Self.at(0)))
        // The project name arrives later but is more trusted: it becomes the term, UTLDR a heard-as form.
        #expect(book.observe(TermObservation(spelling: "YouTLDR", source: .project, at: Self.at(1))) == .aliased(into: "YouTLDR"))
        #expect(book.terms.count == 1)
        let t = book.terms[0]
        #expect(t.spelling == "YouTLDR")
        #expect(t.aliases.map(\.form) == ["UTLDR"])
        #expect(t.aliases[0].count == 32)
        #expect(t.sightings == 33)
        // A less trusted sound-alike just adds a heard-as form.
        #expect(book.observe(TermObservation(spelling: "Realbird", source: .history, count: 9, at: Self.at(0))) == .added)
        #expect(book.observe(TermObservation(spelling: "Reelbird", source: .project, at: Self.at(0))) == .aliased(into: "Reelbird"))
        #expect(book.term("Reelbird")?.aliases.map(\.form) == ["Realbird"])
    }

    @Test func commonWordsNeverMergeBySound() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "Claude", source: .history, count: 5, at: Self.at(0), isCommonWord: true))
        book.observe(TermObservation(spelling: "Cloud", source: .history, count: 5, at: Self.at(0), isCommonWord: true))
        #expect(book.terms.count == 2)
    }

    @Test func heardAsFormsNeverPointAtAnotherTerm() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "Nvidia", source: .history, count: 15, at: Self.at(0)))
        book.observe(TermObservation(spelling: "InVideo", source: .history, heardAs: ["NVIDIA": 6, "envideo": 2, "in video": 3], count: 2, at: Self.at(0)))
        #expect(book.term("InVideo")?.aliases.map(\.form) == ["envideo"])  // spacing variants are not stored
    }

    @Test func junkLearnedEntriesAreBlocked() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "Nvidia", source: .history, count: 15, at: Self.at(0)))
        // The five junk entries Wispr learned from his edits.
        #expect(book.observeLearned(spelling: "2k", heard: "maximum", source: .wisprDictionary, count: 6, at: Self.at(0)) != .added)
        #expect(book.observeLearned(spelling: "nviidia", heard: "the GPU", source: .wisprDictionary, count: 1, at: Self.at(0)) != .added)
        #expect(book.observeLearned(spelling: "Polished.btn thi", heard: "Polished", source: .wisprDictionary, count: 1, at: Self.at(0)) != .added)
        #expect(book.observeLearned(spelling: "invideo", heard: "NVIDIA", source: .wisprDictionary, count: 6, at: Self.at(0)) != .added)
        #expect(book.observeLearned(spelling: "cain", heard: "Abel", source: .wisprDictionary, count: 1, at: Self.at(0)) != .added)
        // Real corrections pass.
        #expect(book.observeLearned(spelling: "Anthropic", heard: "entropic", source: .wisprDictionary, count: 40, at: Self.at(0)) == .added)
        #expect(book.observeLearned(spelling: "Umami", heard: "Omami", source: .wisprDictionary, count: 8, at: Self.at(0)) == .added)
        #expect(book.observeLearned(spelling: "elevenlabs", heard: "Alvelabs", source: .wisprDictionary, count: 24, at: Self.at(0)) == .added)
        #expect(book.terms.filter { $0.state == .blocked }.count == 5)
        // Blocked spellings never come back.
        if case .rejected = book.observe(TermObservation(spelling: "nviidia", source: .history, count: 9, at: Self.at(2))) {} else {
            Issue.record("blocked term came back")
        }
        #expect(book.term("Anthropic")?.aliases.first?.form == "entropic")
    }

    @Test func liveAfterTwoSightingsOrATrustedSource() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "Kalshi", source: .history, count: 1, at: Self.at(0)))
        book.observe(TermObservation(spelling: "Hetzner", source: .history, count: 2, at: Self.at(0)))
        book.observe(TermObservation(spelling: "Saylark", source: .project, at: Self.at(0)))
        book.refresh(now: Self.at(1))
        #expect(book.term("Kalshi")?.state == .candidate)
        #expect(book.term("Hetzner")?.state == .live)
        #expect(book.term("Saylark")?.state == .live)
    }

    @Test func unusedTermsRetireAndComeBack() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "Godot", source: .history, count: 4, at: Self.at(0)))
        book.observe(TermObservation(spelling: "Pinned", source: .manual, at: Self.at(0)))
        book.refresh(now: Self.at(31))
        #expect(book.term("Godot")?.state == .retired)
        #expect(book.term("Pinned")?.state == .live)
        book.observe(TermObservation(spelling: "Godot", source: .history, at: Self.at(32)))
        book.refresh(now: Self.at(32))
        #expect(book.term("Godot")?.state == .live)
    }

    @Test func capKeepsTheBestTerms() {
        var rules = VocabularyRules()
        rules.cap = 3
        var book = VocabularyBook(rules: rules)
        for (i, name) in ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].enumerated() {
            book.observe(TermObservation(spelling: name + "x", source: .history, count: 2 + i * 10, at: Self.at(0)))
        }
        book.observe(TermObservation(spelling: "Zulu", source: .project, at: Self.at(0)))
        book.refresh(now: Self.at(0))
        #expect(book.live.count == 3)
        #expect(Set(book.live.map(\.spelling)) == ["Zulu", "Echox", "Deltax"])
        #expect(book.term("Alphax")?.note?.contains("cap") == true)
        // Deterministic: the same inputs give the same book.
        var again = VocabularyBook(rules: rules)
        for (i, name) in ["Alpha", "Bravo", "Charlie", "Delta", "Echo"].enumerated().reversed() {
            again.observe(TermObservation(spelling: name + "x", source: .history, count: 2 + i * 10, at: Self.at(0)))
        }
        again.observe(TermObservation(spelling: "Zulu", source: .project, at: Self.at(0)))
        again.refresh(now: Self.at(0))
        #expect(again == book)
    }

    @Test func mishearingsFoldIntoTrustedTerms() {
        var book = VocabularyBook()
        book.observe(TermObservation(spelling: "ShipTiffin", source: .project, at: Self.at(0)))
        book.observe(TermObservation(spelling: "Shiftfn", source: .history, count: 6, at: Self.at(0)))
        book.observe(TermObservation(spelling: "Kubernetes", source: .history, count: 6, at: Self.at(0)))
        let folds = book.foldMishearings()
        #expect(folds.map(\.from) == ["Shiftfn"])
        #expect(book.term("Shiftfn") == nil)
        #expect(book.term("ShipTiffin")?.aliases.map(\.form) == ["Shiftfn"])
        #expect(book.term("ShipTiffin")?.sightings == 7)
    }

    @Test func rebuildKeepsManualAndBlocked() {
        var old = VocabularyBook()
        old.observe(TermObservation(spelling: "Pinned", source: .manual, at: Self.at(0)))
        old.block(spelling: "nviidia", reason: "junk", at: Self.at(0))
        var fresh = VocabularyBook()
        fresh.observe(TermObservation(spelling: "nviidia", source: .history, count: 3, at: Self.at(0)))
        fresh.carryOver(from: old)
        #expect(fresh.term("Pinned") != nil)
        #expect(fresh.term("nviidia")?.state == .blocked)
    }
}

@Suite struct TermSwapperTests {
    static func words(_ s: String, confidence: [Float]? = nil) -> [TranscriptWord] {
        s.split(separator: " ").enumerated().map { i, w in
            TranscriptWord(text: String(w), start: Double(i), end: Double(i) + 0.5, confidence: confidence?[i] ?? 0.95)
        }
    }

    static func term(_ spelling: String, aliases: [String: Int] = [:], common: Bool = false, source: TermSource = .project) -> VocabularyTerm {
        VocabularyTerm(
            spelling: spelling, aliases: aliases.map { HeardAs(form: $0.key, count: $0.value, source: .correction) },
            sources: [source], sightings: 5, firstSeen: Date(), lastSeen: Date(), state: .live, isCommonWord: common)
    }

    static let common = CommonWords(["real", "bird", "the", "for", "a", "we", "use", "cloud", "short", "candy", "on", "and", "it", "is", "deploy", "to", "fall", "back", "sign", "up", "i", "think", "or"])

    static func run(_ text: String, confidence: [Float]? = nil, terms: [VocabularyTerm]) -> (String, [TermChange]) {
        let swapper = TermSwapper(terms: terms, common: common)
        let w = words(text, confidence: confidence)
        let changes = swapper.propose(w)
        return (TermSwapper.apply(changes, to: Transcript(text: text, words: w)).text, changes)
    }

    @Test func distinctiveHeardAsFormIsAlwaysSwapped() {
        let (text, changes) = Self.run("deploy UTLDR to Vercel.", terms: [Self.term("YouTLDR", aliases: ["UTLDR": 32])])
        #expect(text == "deploy YouTLDR to Vercel.")
        #expect(changes.map(\.rule) == [.alias])
    }

    @Test func ordinaryWordAliasNeedsLowConfidence() {
        let terms = [Self.term("Reelbird", aliases: ["real bird": 21])]
        #expect(Self.run("a real bird is", terms: terms).0 == "a real bird is")
        #expect(Self.run("a real bird is", confidence: [0.9, 0.4, 0.8, 0.9], terms: terms).0 == "a Reelbird is")
    }

    @Test func aliasSeenOnceIsIgnored() {
        #expect(Self.run("we use Omami", terms: [Self.term("Umami", aliases: ["Omami": 1])]).0 == "we use Omami")
    }

    @Test func spacingAndCaseFixesKeepPunctuation() {
        let (text, changes) = Self.run("on Ship Tiffin, and youtldr.", terms: [Self.term("ShipTiffin"), Self.term("YouTLDR")])
        #expect(text == "on ShipTiffin, and YouTLDR.")
        #expect(changes.map(\.rule) == [.spacing, .spacing])
    }

    @Test func soundAlikeOnlyWhenUnsureAndNotOrdinaryEnglish() {
        let terms = [Self.term("ShipTiffin")]
        #expect(Self.run("launch on Shiftfn now", terms: terms).0 == "launch on Shiftfn now")
        let (text, changes) = Self.run("launch on Shiftfn now", confidence: [0.9, 0.9, 0.3, 0.9], terms: terms)
        #expect(text == "launch on ShipTiffin now")
        #expect(changes.first?.rule == .sound)
        // Ordinary words never become a sound-alike target, however unsure.
        #expect(Self.run("the cloud", confidence: [0.2, 0.2], terms: [Self.term("Claudex")]).0 == "the cloud")
    }

    @Test func commonWordTermsAreNotForced() {
        // "Fal" is a dictionary-like term; "fall back" is never rewritten.
        let terms = [Self.term("Dibs", common: true), Self.term("Fal", common: true)]
        #expect(Self.run("we fall back to dibs", confidence: [0.2, 0.2, 0.2, 0.2, 0.2], terms: terms).0 == "we fall back to dibs")
    }

    @Test func knownTermsAreNeverRewritten() {
        let terms = [Self.term("Nvidia"), Self.term("InVideo", aliases: ["Nvidia": 6])]
        #expect(Self.run("Nvidia GPUs", confidence: [0.1, 0.9], terms: terms).0 == "Nvidia GPUs")
    }

    @Test func pastDictationTermsGetNoCaseFixOrOrdinaryJoin() {
        let terms = [Self.term("Quillora", source: .history), Self.term("signup", source: .history), Self.term("Hetzner", source: .history)]
        #expect(Self.run("quillora and sign up", terms: terms).0 == "quillora and sign up")
        // A spacing fix that is not ordinary English still applies.
        #expect(Self.run("on Hetz ner", terms: terms).0 == "on Hetzner")
    }

    @Test func soundAlikeLeavesFunctionWordsOut() {
        let (text, _) = Self.run("deploy or Shiptiffen", confidence: [0.9, 0.3, 0.3], terms: [Self.term("ShipTiffin")])
        #expect(text == "deploy or ShipTiffin")
    }

    @Test func pluralsOfKnownTermsAreLeftAlone() {
        let terms = [Self.term("Reddit"), Self.term("Redis")]
        #expect(Self.run("ask Reddit's users", confidence: [0.9, 0.2, 0.9], terms: terms).0 == "ask Reddit's users")
    }

    @Test func shortOrdinaryWordsNeverFormAnAlias() {
        let terms = [Self.term("UBI", aliases: ["up I": 4])]
        #expect(Self.run("it is up I think", confidence: [0.2, 0.2, 0.2, 0.2, 0.2], terms: terms).0 == "it is up I think")
    }

    @Test func applyKeepsTimingsAndTokens() {
        let w = Self.words("ship tiffin works")
        let tokens = [TranscriptToken(text: " ship", start: 0, end: 0.5, confidence: 0.9, tokenId: 7)]
        let t = TermSwapper.apply([TermChange(start: 0, count: 2, original: "ship tiffin", replacement: "ShipTiffin", rule: .spacing, confidence: 0.9)], to: Transcript(text: "ship tiffin works", words: w, tokens: tokens))
        #expect(t.words.map(\.text) == ["ShipTiffin", "works"])
        #expect(t.words[0].start == 0 && t.words[0].end == 1.5)
        #expect(t.tokens == tokens)
    }
}

@Suite struct TermRecallTests {
    @Test func countsCorrectAndFalseInsertions() {
        var r = TermRecall(terms: ["YouTLDR", "ShipTiffin", "Hacker News"])
        let take = r.add(reference: "Use YouTLDR and YouTLDR on ShipTiffin. Read Hacker News.", hypothesis: "Use UTLDR and YouTLDR on Ship Tiffin, read hacker news. YouTLDR")
        #expect(take["YouTLDR"]?.reference == 2)
        #expect(take["YouTLDR"]?.correct == 2)
        #expect(take["YouTLDR"]?.falseInsertions == 0)
        #expect(take["ShipTiffin"]?.correct == 0)
        #expect(take["ShipTiffin"]?.lenientCorrect == 1)
        #expect(take["Hacker News"]?.correct == 1)
        r.add(reference: "plain text", hypothesis: "ShipTiffin text")
        #expect(r.total().falseInsertions == 1)
        #expect(r.total(["YouTLDR"]).reference == 2)
    }
}

@Suite struct TermRankerTests {
    @Test func projectContextRanksItsTermsFirst() {
        let now = Date()
        func t(_ s: String, _ n: Int, projects: [String] = []) -> VocabularyTerm {
            VocabularyTerm(spelling: s, sources: [.history], projects: projects, sightings: n, firstSeen: now, lastSeen: now, state: .live)
        }
        let terms = [t("Vercel", 100), t("Supabase", 90), t("Zentrik", 2, projects: ["zentrik"]), t("Quillora", 3, projects: ["zentrik"])]
        #expect(TermRanker.select(terms, context: .none, limit: 2, now: now).map(\.spelling) == ["Vercel", "Supabase"])
        let inProject = VocabularyContext(appBundleID: "com.anthropic.claudefordesktop", projectFolder: "/Users/x/code/zentrik")
        #expect(TermRanker.select(terms, context: inProject, limit: 2, now: now).map(\.spelling) == ["Zentrik", "Quillora"])
    }
}
