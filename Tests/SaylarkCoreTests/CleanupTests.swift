import Testing
@testable import SaylarkCore

/// Golden cases for `Cleanup`. Strings are invented; they copy the shapes seen in real dictation.
@Suite struct CleanupTests {
    @Test(arguments: [
        // Fillers
        ("Um, so I think we should ship it.", "So I think we should ship it."),
        ("Yes, um, I agree.", "Yes, I agree."),
        ("We could, uh, try the other branch.", "We could, try the other branch."),
        ("Um, uh, let me check.", "Let me check."),
        ("and then uh you open the file", "and then you open the file"),
        ("It works, hmm.", "It works."),
        ("It works. Um.", "It works."),
        ("Er, what was the name?", "What was the name?"),
        ("Uh uh, wait.", "Wait."),
        ("The error is there.", "The error is there."),
        ("Erm the user said hmm okay", "The user said okay"),
        // Words that only look like fillers stay
        ("Her umbrella was by the door.", "Her umbrella was by the door."),
        ("Ahh that hurt, mmhm.", "Ahh that hurt, mmhm."),
        // Stutter repeats
        ("the the build is green", "the build is green"),
        ("The the build is green.", "The build is green."),
        ("I I I think it works.", "I think it works."),
        ("I think I think it works.", "I think it works."),
        ("so we go to the go to the next page", "so we go to the next page"),
        ("and, and then it broke", "and then it broke"),
        ("we we, we tried that", "we tried that"),
        ("it's like like a cache", "it's like a cache"),
        ("open the uh the settings", "open the settings"),
        // Repeats that are meant stay
        ("It was very very fast.", "It was very very fast."),
        ("I know that that is true.", "I know that that is true."),
        ("No no, that's fine.", "No no, that's fine."),
        ("It works. It works.", "It works. It works."),
        ("Version 5 5 shipped.", "Version 5 5 shipped."),
        // New line and new paragraph
        ("Hi team. New line. The deploy is done.", "Hi team.\nThe deploy is done."),
        ("Hi team, new line, the deploy is done.", "Hi team\nThe deploy is done."),
        ("First point. New paragraph. Second point.", "First point.\n\nSecond point."),
        ("Thanks. New line. New line. Bye.", "Thanks.\n\nBye."),
        ("New line. Start here.", "\nStart here."),
        ("add a new line to the file", "add a new line to the file"),
        ("We need a new line.", "We need a new line."),
        ("The output then new line.", "The output then\n"),
        ("this starts a new paragraph of code", "this starts a new paragraph of code"),
    ])
    func golden(input: String, expected: String) {
        #expect(Cleanup.apply(input) == expected)
    }

    @Test func emptyAndSpaces() {
        #expect(Cleanup.apply("") == "")
        #expect(Cleanup.apply("   ") == "")
        #expect(Cleanup.apply("um") == "")
    }

    @Test func keepsExistingLineBreaks() {
        #expect(Cleanup.apply("one\ntwo") == "one\ntwo")
    }

    /// Identifiers, numbers, units and addresses pass through untouched (a cloud formatter is
    /// known to mangle an IP, an email domain and "100 GB"). Only fillers around them go.
    @Test(arguments: [
        ("The server is at 76.76.21.21, um, on port 8080.", "The server is at 76.76.21.21, on port 8080."),
        ("We need 100 GB, uh, on the one dollar, two dollar plan.", "We need 100 GB, on the one dollar, two dollar plan."),
        ("Send it from no-reply@example.com please.", "Send it from no-reply@example.com please."),
        ("Open https://example.com/a/b?x=1&y=2 now.", "Open https://example.com/a/b?x=1&y=2 now."),
        ("Edit /Users/me/Desktop/clip.mp4 and ~/notes.md today.", "Edit /Users/me/Desktop/clip.mp4 and ~/notes.md today."),
        ("Run rm -rf build then npm run dev.", "Run rm -rf build then npm run dev."),
        ("Ping 192.168.1.1 192.168.1.1 twice.", "Ping 192.168.1.1 192.168.1.1 twice."),
        ("Set it to v2 v2 for now.", "Set it to v2 v2 for now."),
        ("Call foo.bar foo.bar again.", "Call foo.bar foo.bar again."),
        ("It is 5 mm wide.", "It is 5 mm wide."),
        ("Take her to the ER now.", "Take her to the ER now."),
        ("He said HMM loudly.", "He said HMM loudly."),
        ("What it is is a cache.", "What it is is a cache."),
        ("No no, not that one.", "No no, not that one."),
        ("Um, iOS is fine.", "iOS is fine."),
        ("Uh, macOS 26 is out.", "macOS 26 is out."),
        ("Um, /tmp is full.", "/tmp is full."),
        ("Um, 4K looks good.", "4K looks good."),
        ("The ratio is 16:9, uh, not 4:3.", "The ratio is 16:9, not 4:3."),
        ("It costs $1.50 or €2.", "It costs $1.50 or €2."),
        ("Use 480p at 30 fps.", "Use 480p at 30 fps."),
        ("Call me at 555-0100.", "Call me at 555-0100."),
    ])
    func identifiersPassThrough(input: String, expected: String) {
        #expect(Cleanup.apply(input) == expected)
    }

    /// Cleanup only ever removes fillers and stutters: every other word of the input is still
    /// there, in order.
    @Test func neverDropsContentWords() {
        let inputs = [
            "So um the plan is to move 76.76.21.21 to the new box, uh, and keep 100 GB free.",
            "I I think we we should rename foo_bar to fooBar in src/app.ts.",
            "Okay okay, the the deploy is at https://x.dev/deploy?id=42 now.",
        ]
        for input in inputs {
            let kept = Cleanup.apply(input).split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
            let said = input.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters).lowercased() }
                .filter { !Cleanup.fillers.contains($0) }
            var it = kept.makeIterator()
            var next = it.next()
            var missing: [String] = []
            for word in said {
                if word == next { next = it.next() } else if !["i", "we", "the", "okay"].contains(word) { missing.append(word) }
            }
            #expect(missing.isEmpty, "\(input) lost \(missing)")
        }
    }
}

/// Paragraph breaks from long pauses.
@Suite struct ParagraphTests {
    /// Words 0.3 s long, 0.2 s apart, with a longer gap before the indices in `pauses`.
    static func words(_ text: String, pauses: [Int: Double], start: Double = 0) -> [TranscriptWord] {
        var t = start
        return text.split(separator: " ").enumerated().map { i, w in
            t += pauses[i] ?? (i == 0 ? 0 : 0.2)
            defer { t += 0.3 }
            return TranscriptWord(text: String(w), start: t, end: t + 0.3, confidence: 0.9)
        }
    }

    static let first = "This is the first part of what I want to say about the plan."
    static let second = "Then here is the second part with more detail about the work."
    static var text: String { first + " " + second }
    static var firstCount: Int { first.split(separator: " ").count }

    @Test func longPauseAfterASentenceBecomesABlankLine() {
        let w = Self.words(Self.text, pauses: [Self.firstCount: 1.5])
        #expect(Paragraphs.apply(Self.text, words: w, duration: 30) == Self.first + "\n\n" + Self.second)
    }

    @Test func shortTakesGetNoParagraphs() {
        let w = Self.words(Self.text, pauses: [Self.firstCount: 1.5])
        #expect(Paragraphs.apply(Self.text, words: w, duration: 15) == Self.text)
    }

    @Test func shortPauseIsNoBreak() {
        let w = Self.words(Self.text, pauses: [Self.firstCount: 0.9])
        #expect(Paragraphs.apply(Self.text, words: w, duration: 30) == Self.text)
    }

    /// A thinking pause mid-sentence is not a paragraph, unless it is very long.
    @Test func midSentencePauseNeedsToBeLonger() {
        let mid = 9  // inside the first sentence
        #expect(Paragraphs.apply(Self.text, words: Self.words(Self.text, pauses: [mid: 1.5]), duration: 30) == Self.text)
        let broken = Paragraphs.apply(Self.text, words: Self.words(Self.text, pauses: [mid: 3.2]), duration: 30)
        #expect(broken.contains("\n\n"))
        #expect(broken.replacingOccurrences(of: "\n\n", with: " ") == Self.text)
    }

    /// No one-word paragraphs: a pause right after "Okay." does not break.
    @Test func tinyParagraphsAreNotMade() {
        let text = "Okay. " + Self.text
        #expect(Paragraphs.apply(text, words: Self.words(text, pauses: [1: 2.0]), duration: 30) == text)
    }

    /// Words that don't line up with the text: leave it alone rather than guess.
    @Test func mismatchedWordsLeaveTheTextAlone() {
        let w = Self.words(Self.text + " extra", pauses: [Self.firstCount: 1.5])
        #expect(Paragraphs.apply(Self.text, words: w, duration: 30) == Self.text)
    }

    /// Breaks survive cleanup, and cleanup never merges words across them.
    @Test func breaksSurviveCleanup() {
        let raw = "Um, " + Self.text
        let w = Self.words(raw, pauses: [Self.firstCount + 1: 1.5])
        let out = Cleanup.apply(Paragraphs.apply(raw, words: w, duration: 30))
        #expect(out == Self.first + "\n\n" + Self.second)
    }

    /// Only blank lines are added: removing them gives back the input exactly.
    @Test func onlyAddsBreaks() {
        var pauses: [Int: Double] = [:]
        for i in stride(from: 5, to: 24, by: 4) { pauses[i] = 1.4 + Double(i % 3) }
        let w = Self.words(Self.text, pauses: pauses)
        let out = Paragraphs.apply(Self.text, words: w, duration: 60)
        #expect(out.replacingOccurrences(of: "\n\n", with: " ") == Self.text)
    }
}
