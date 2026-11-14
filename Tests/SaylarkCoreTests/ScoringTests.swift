import Testing
@testable import SaylarkCore

@Suite struct ScoringTests {
    @Test func normalisesLikeScorePy() {
        #expect(ScoringText.words("Hello, World! It's next-gen/fast_ok.") == ["hello", "world", "it's", "next", "gen", "fast", "ok"])
        #expect(ScoringText.words("the 90's 'quoted'") == ["the", "90", "s", "quoted"])
        #expect(ScoringText.words("Um, so uh yes", dropFillers: true) == ["so", "yes"])
        #expect(ScoringText.words("It\u{2019}s fine") == ["it's", "fine"])
    }

    @Test func distanceAndAlignment() {
        let r = ["a", "b", "c", "d"], h = ["a", "x", "c", "d", "e"]
        #expect(WordAlignment.distance(r, h) == 2)
        let pairs = WordAlignment.align(r, h)
        #expect(pairs.count == 5)
        #expect(pairs[1] == .init(ref: 1, hyp: 1))
        #expect(pairs.last == .init(ref: nil, hyp: 4))
        #expect(WordAlignment.distance([], ["a"]) == 1)
    }

    @Test func tally() {
        var t = WordErrorTally()
        t.add(reference: "the cat sat", hypothesis: "the cat um sat")
        t.add(reference: "a b", hypothesis: "a c")
        #expect(t.errors == 1 && t.words == 5)
    }

    @Test func tokensToWords() {
        let tokens = [
            TranscriptToken(text: " Hel", start: 0, end: 0.1, confidence: 0.9),
            TranscriptToken(text: "lo", start: 0.1, end: 0.2, confidence: 0.5),
            TranscriptToken(text: ",", start: 0.2, end: 0.2, confidence: 0.99),
            TranscriptToken(text: "▁world", start: 0.3, end: 0.5, confidence: 0.8),
        ]
        let words = TranscriptToken.words(from: tokens)
        #expect(words.map(\.text) == ["Hello,", "world"])
        #expect(words[0].confidence == 0.5 && words[0].end == 0.2)
    }

    @Test func joinAndShift() {
        let a = Transcript(text: "One.", words: [.init(text: "One.", start: 0, end: 1, confidence: 1)])
        let b = Transcript(text: "Two.", words: [.init(text: "Two.", start: 0, end: 1, confidence: 1)]).shifted(by: 10)
        let j = Transcript.joined([a, .empty, b])
        #expect(j.text == "One. Two.")
        #expect(j.words.last?.start == 10)
    }
}

@Suite struct TermHarvestTests {
    let harvest = TermHarvest(dictionary: ["deploy", "to", "the", "app", "now", "we", "use", "for", "video", "shift", "loom", "it", "and"])

    @Test func rareWords() {
        let t = TextToken.tokenize("We use Zorblat and fooBar for M4 video. Deploy it now")
        let rare = t.filter(harvest.isRare).map(\.text)
        #expect(rare == ["Zorblat", "fooBar", "M4"])
    }

    @Test func findsMissesAndHits() {
        let c = harvest.compare(
            reference: "Deploy the app to Zorblat now. We use Loom for video, and Ship Tiffin.",
            heard: "Deploy the app to sore blat now. We use loan for video, and ShipTiffin.")
        #expect(c.misses.map(\.term) == ["Zorblat", "Loom", "Ship Tiffin"])
        #expect(c.misses[0].heard == "sore blat")
        #expect(c.misses[2].formatOnly)
        #expect(!c.misses[0].formatOnly)
        #expect(TermHarvest.groupKey("Ship Tiffin") == "shiptiffin")
    }

    @Test func fuzzyContainment() {
        let long = "ok so here is my message we use the zorblat app now and then more text".split(separator: " ").map(String.init)
        let short = "we use zorblot app now".split(separator: " ").map(String.init)
        let m = FuzzyContainment.match(short, in: long)!
        #expect(m.range == 6..<12)
        #expect(abs(m.score - 0.6) < 0.01)
    }
}
