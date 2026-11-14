import Foundation
import Testing
@testable import SaylarkCore

/// The user's dictionary file: parsing, editing that keeps what the user wrote, and the terms the
/// corrector gets. Files live in a temp folder only.
@Suite struct DictionaryFileTests {
    static func tempURL() -> URL {
        let base = ProcessInfo.processInfo.environment["SL_TEST_TMP"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("dict-\(UUID().uuidString)/dictionary.txt")
    }

    static let sample = """
        # my words
        ShipTiffin: ship tiffin, shift tiffin
        YouTLDR:UTLDR,  you tldr ,UTLDR

        kubectl
        : no term here
        Foo, Bar
        Reelbird: real bird
        shiptiffin: shipdiffin
        """

    @Test func parsesTermsAliasesCommentsAndSkipsBadLines() {
        let f = DictionaryFile.parse(Self.sample)
        #expect(f.entries.map(\.term) == ["ShipTiffin", "YouTLDR", "kubectl", "Reelbird"])
        // A term written twice is one entry; repeated and self aliases go.
        #expect(f.entry("shiptiffin")?.aliases == ["ship tiffin", "shift tiffin", "shipdiffin"])
        #expect(f.entry("YouTLDR")?.aliases == ["UTLDR", "you tldr"])
        #expect(f.problems.map(\.line) == [6, 7])
        #expect(f.problems[0].reason == "no term before the colon")
        #expect(f.problems[1].reason.contains("comma"))
    }

    @Test func garbageNeverCrashesAndRoundTripsAsWritten() {
        let junk = "::::\n,,,\n#\n\u{0}\n" + String(repeating: "x", count: 200) + "\n   \n😀: 🙂\nok: \n"
        let f = DictionaryFile.parse(junk)
        #expect(f.entries.map(\.term) == ["ok"])
        #expect(f.text == junk)
    }

    @Test func editsKeepCommentsOrderAndBadLines() {
        var f = DictionaryFile.parse(Self.sample)
        f.add("Kalshi", aliases: ["Calci"])
        f.add("YouTLDR", aliases: ["ytldr", "utldr"])
        let removed = f.remove("kubectl"), missing = f.remove("nothing")
        #expect(removed && !missing)
        f.set(DictionaryEntry(term: "Reelbird", aliases: ["Realbird"]), replacing: "Reelbird")
        f.set(DictionaryEntry(term: "ShipTiffin", aliases: ["ship tiffin", "shift tiffin"]))
        let lines = f.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == "# my words")
        #expect(lines.contains(": no term here") && lines.contains("Foo, Bar"))
        #expect(lines.contains("YouTLDR: UTLDR, you tldr, ytldr"))
        #expect(lines.contains("Reelbird: Realbird"))
        #expect(!lines.contains("kubectl"))
        // The second ShipTiffin line folds into the first when that entry is rewritten.
        f.add("ShipTiffin")
        #expect(f.text.components(separatedBy: "hiptiffin:").count == 1)
        #expect(f.entries.last?.term == "Kalshi")
        #expect(DictionaryFile.parse(f.text).entries == f.entries)
    }

    @Test func renameReplacesInPlace() {
        var f = DictionaryFile.parse("A\nRelbird: real bird\nC\n")
        f.set(DictionaryEntry(term: "Reelbird", aliases: ["real bird"]), replacing: "Relbird")
        #expect(f.text == "A\nReelbird: real bird\nC\n")
    }

    @Test func updateCreatesTheFileWithTheHeader() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DictionaryFile.update(url) { $0.add("Codex", aliases: ["codecs"]) }
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix(DictionaryFile.header))
        #expect(text.hasSuffix("\nCodex: codecs\n"))
        #expect(try DictionaryFile.load(url).entries == [DictionaryEntry(term: "Codex", aliases: ["codecs"])])
    }

    @Test func termsKeepTheCorrectorGuards() {
        let common = CommonWords(["dibs", "real", "bird", "sign", "up"])
        let f = DictionaryFile.parse("Dibs\nReelbird: real bird, Relbird\nsignup\n")
        let terms = f.terms(common: common)
        #expect(terms.allSatisfy { $0.state == .live })
        let dibs = terms[0], reelbird = terms[1], signup = terms[2]
        #expect(dibs.isCommonWord && !reelbird.isCommonWord)
        #expect(reelbird.sources == [.manual] && reelbird.aliases.map(\.count) == [2, 2])
        // All-lowercase terms get the cautious source: no case-only fixes, no joining ordinary words.
        #expect(signup.sources == [.history] && !signup.bestSource.isTrusted)
    }

    @Test func swapsAMisheardFormButLeavesOrdinaryWordsTheRecogniserWasSureOf() {
        let common = CommonWords(["real", "bird", "the", "a", "saw"])
        let terms = DictionaryFile.parse("Reelbird: real bird, Relbird\n").terms(common: common)
        func run(_ words: [(String, Float)]) -> String {
            let w = words.enumerated().map { TranscriptWord(text: $1.0, start: Double($0), end: Double($0) + 0.3, confidence: $1.1) }
            let swapper = TermSwapper(terms: terms, common: common)
            return TermSwapper.apply(swapper.propose(w), to: Transcript(text: w.map(\.text).joined(separator: " "), words: w)).text
        }
        #expect(run([("open", 0.9), ("Relbird", 0.9)]) == "open Reelbird")
        #expect(run([("saw", 0.9), ("a", 0.9), ("real", 0.95), ("bird", 0.95)]) == "saw a real bird")
        #expect(run([("open", 0.9), ("real", 0.3), ("bird", 0.3)]) == "open Reelbird")
    }
}

@Suite struct FileWatcherTests {
    final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func wait(_ seconds: Double, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func seesAtomicSavesInPlaceWritesAndDeletes() async throws {
        let url = DictionaryFileTests.tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try DictionaryFile().write(to: url)
        let count = Count()
        let watcher = FileWatcher(url: url, interval: 0.2) { count.bump() }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(count.value == 0)

        try Data("Codex\n".utf8).write(to: url, options: .atomic)
        await wait(2) { count.value >= 1 }
        #expect(count.value == 1)

        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data("Kalshi\n".utf8))
        try h.close()
        await wait(2) { count.value >= 2 }
        #expect(count.value == 2)

        try FileManager.default.removeItem(at: url)
        await wait(2) { count.value >= 3 }
        #expect(count.value == 3)
        try Data("Back\n".utf8).write(to: url)
        await wait(2) { count.value >= 4 }
        #expect(count.value == 4)
    }
}
