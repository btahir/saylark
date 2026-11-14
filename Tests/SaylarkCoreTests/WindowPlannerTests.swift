import Testing
@testable import SaylarkCore

@Suite struct WindowPlannerTests {
    let chunk = 4096

    /// Feeds probabilities chunk by chunk and returns the cuts, applying each at its range middle.
    func run(_ probs: [Float], config: WindowPlanner.Config = .init()) -> [WindowPlanner.Cut] {
        var planner = WindowPlanner(config: config)
        var cuts: [WindowPlanner.Cut] = []
        for (k, p) in probs.enumerated() {
            if let cut = planner.observe(start: k * chunk, end: (k + 1) * chunk, probability: p) {
                cuts.append(cut)
                planner.didCut(at: (cut.range.lowerBound + cut.range.upperBound) / 2)
            }
        }
        return cuts
    }

    @Test func noCutBeforeMinimumLength() {
        // 8 s of speech with a pause at 4 s: too early to close.
        var probs = [Float](repeating: 0.9, count: 31)
        probs[15] = 0.1
        #expect(run(probs).isEmpty)
    }

    @Test func cutsAtFirstPauseAfterTenSeconds() {
        var probs = [Float](repeating: 0.9, count: 60)  // ~15 s
        probs[20] = 0.1  // 5 s: ignored
        probs[42] = 0.1  // ~10.75 s: closes here
        probs[50] = 0.1
        let cuts = run(probs)
        #expect(cuts.count == 1)
        #expect(cuts[0].range == (42 * chunk)..<(43 * chunk))
        #expect(!cuts[0].isHardCut)
    }

    @Test func longerMinimumPauseNeedsTwoChunks() {
        var config = WindowPlanner.Config()
        config.minPause = 0.5
        var probs = [Float](repeating: 0.9, count: 70)
        probs[42] = 0.1
        probs[50] = 0.1
        probs[51] = 0.1
        let cuts = run(probs, config: config)
        #expect(cuts.count == 1)
        #expect(cuts[0].range == (50 * chunk)..<(52 * chunk))
    }

    @Test func hardCutAtFourteenSeconds() {
        let probs = [Float](repeating: 0.9, count: 70)  // ~17.9 s, no pause
        let cuts = run(probs)
        #expect(cuts.count == 1)
        #expect(cuts[0].isHardCut)
        #expect(cuts[0].range.upperBound == 224_000)
        #expect(cuts[0].range.lowerBound == 224_000 - 24_000)
    }

    @Test func silenceAtStartDoesNotCutEarly() {
        var probs = [Float](repeating: 0.1, count: 10)
        probs += [Float](repeating: 0.9, count: 10)
        #expect(run(probs).isEmpty)
    }

    @Test func manyWindowsInALongDictation() {
        // 2 minutes of speech with a short pause every 3 s.
        let probs = (0..<470).map { $0 % 12 == 11 ? Float(0.1) : 0.9 }
        let cuts = run(probs)
        #expect(cuts.count >= 9 && cuts.count <= 12)
        var last = 0
        for cut in cuts {
            let middle = (cut.range.lowerBound + cut.range.upperBound) / 2
            #expect(middle - last >= 9 * 16_000 && middle - last <= 14 * 16_000)
            last = middle
        }
    }

    @Test func quietPointFindsSilence() {
        var samples = [Float](repeating: 0.5, count: 16_000)
        for i in 9_000..<9_400 { samples[i] = 0 }
        let p = QuietPoint.find(in: samples, range: 0..<16_000)
        #expect(p >= 9_000 && p < 9_400)
    }
}
