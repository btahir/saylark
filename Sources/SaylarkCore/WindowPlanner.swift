import Foundation

/// Decides where to close transcription windows in a live 16 kHz stream, from voice-activity
/// probabilities (one per VAD chunk). Platform-free so it can be tested with made-up probabilities.
///
/// A window closes at the first pause once it is at least `minWindow` long, or at a hard cut at
/// `maxWindow`. The planner only returns a sample range to cut in; `QuietPoint` picks the exact
/// sample (the quietest frame), so a cut never lands in the middle of a word if it can help it.
public struct WindowPlanner: Sendable {
    public struct Config: Sendable, Equatable {
        public var sampleRate = 16_000
        /// Close at the first pause after this many seconds.
        public var minWindow: Double = 10
        /// Cut here even without a pause. Parakeet's encoder takes 15 s at most; a longer window
        /// needs two encoder passes (about 125 ms instead of 55 ms), so the default keeps every
        /// window, plus up to 1 s re-heard from the previous one, inside 15 s.
        public var maxWindow: Double = 14
        /// Shortest pause that closes a window. Silero runs on 256 ms chunks, so the pause is
        /// counted in whole chunks: 0.25 s means one silent chunk.
        public var minPause: Double = 0.25
        /// A chunk is silent when its speech probability is below this.
        public var silenceThreshold: Float = 0.5
        /// How far back from the hard-cut point to look for the quietest frame.
        public var hardCutSearch: Double = 1.5

        public init() {}
    }

    /// Where to cut: somewhere inside `range` (absolute sample indices).
    public struct Cut: Sendable, Equatable {
        public let range: Range<Int>
        public let isHardCut: Bool
    }

    public let config: Config
    /// First sample of the open window.
    public private(set) var windowStart = 0
    private var silentRunStart: Int?
    private var silentRunEnd = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Feeds the VAD result for chunk `start..<end`. Returns a cut when the open window should close.
    /// After a cut, call `didCut(at:)` with the sample actually chosen.
    public mutating func observe(start: Int, end: Int, probability: Float) -> Cut? {
        let rate = Double(config.sampleRate)
        if probability < config.silenceThreshold {
            if silentRunStart == nil { silentRunStart = max(start, windowStart) }
            silentRunEnd = end
        } else {
            silentRunStart = nil
        }

        let minLength = Int(config.minWindow * rate)
        let maxLength = Int(config.maxWindow * rate)
        let minPauseSamples = Int(config.minPause * rate)

        if let runStart = silentRunStart,
            silentRunEnd - runStart >= minPauseSamples,
            silentRunEnd - windowStart >= minLength
        {
            return Cut(range: max(runStart, windowStart + 1)..<silentRunEnd, isHardCut: false)
        }
        if end - windowStart >= maxLength {
            let hardEnd = windowStart + maxLength
            let searchStart = max(windowStart + minLength, hardEnd - Int(config.hardCutSearch * rate))
            return Cut(range: searchStart..<hardEnd, isHardCut: true)
        }
        return nil
    }

    /// Starts the next window at `sample`.
    public mutating func didCut(at sample: Int) {
        windowStart = sample
        if let runStart = silentRunStart, runStart < sample { silentRunStart = sample }
        if silentRunEnd <= sample { silentRunStart = nil }
    }
}

/// Finds the quietest short frame in a range of samples: the best place to split audio.
public enum QuietPoint {
    /// Returns the centre sample of the lowest-energy `frame`-sample frame inside `range`,
    /// stepping by `hop`. Ties go to the frame nearest the middle of the range.
    public static func find(in samples: [Float], range: Range<Int>, frame: Int = 320, hop: Int = 160) -> Int {
        let lower = max(0, range.lowerBound), upper = min(samples.count, range.upperBound)
        guard upper - lower > frame else { return (lower + upper) / 2 }
        let middle = (lower + upper) / 2
        var best = (energy: Float.infinity, centre: middle)
        var start = lower
        while start + frame <= upper {
            var energy: Float = 0
            for i in start..<(start + frame) { energy += samples[i] * samples[i] }
            let centre = start + frame / 2
            if energy < best.energy || (energy == best.energy && abs(centre - middle) < abs(best.centre - middle)) {
                best = (energy, centre)
            }
            start += hop
        }
        return best.centre
    }
}
