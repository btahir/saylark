import Foundation

/// Turns 16 kHz samples into `VoiceLevel`s at a fixed rate (120 per second by default): peak and
/// RMS in dBFS over each block. Blocks are fractional (16000 / 120 = 133.3 samples), so the rate
/// stays exact over a long take.
public struct VoiceLevelMeter: Sendable {
    public let sampleRate: Double
    public let rate: Double
    /// Lowest level reported, for silence.
    public static let floorDB: Float = -120

    private var peak: Float = 0
    private var sumSquares: Double = 0
    private var count = 0
    /// Samples consumed so far in the take.
    private var consumed = 0
    private var blocks = 0

    public init(sampleRate: Double = 16_000, rate: Double = 120) {
        self.sampleRate = sampleRate
        self.rate = rate
    }

    /// Adds samples and returns a level for every block they complete.
    public mutating func add(_ samples: [Float]) -> [VoiceLevel] {
        var out: [VoiceLevel] = []
        var nextEdge = edge(of: blocks + 1)
        for s in samples {
            let a = abs(s)
            if a > peak { peak = a }
            sumSquares += Double(s) * Double(s)
            count += 1
            consumed += 1
            if consumed >= nextEdge {
                let rms = count > 0 ? Float((sumSquares / Double(count)).squareRoot()) : 0
                blocks += 1
                out.append(VoiceLevel(time: Double(consumed) / sampleRate, peakDB: Self.dB(peak), rmsDB: Self.dB(rms)))
                peak = 0; sumSquares = 0; count = 0
                nextEdge = edge(of: blocks + 1)
            }
        }
        return out
    }

    private func edge(of block: Int) -> Int { Int((Double(block) * sampleRate / rate).rounded()) }

    public static func dB(_ linear: Float) -> Float {
        linear > 0 ? max(floorDB, 20 * log10(linear)) : floorDB
    }
}

/// A fixed-size ring of the most recent samples: the pre-roll kept while the mic is warm, so the
/// first syllable before Fn-down is not lost.
public struct PreRollRing: Sendable {
    public let capacity: Int
    private var buffer: [Float]
    private var write = 0
    private var filled = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        buffer = [Float](repeating: 0, count: self.capacity)
    }

    public mutating func add(_ samples: [Float]) {
        if samples.count >= capacity {
            buffer = Array(samples.suffix(capacity))
            write = 0
            filled = capacity
            return
        }
        for s in samples {
            buffer[write] = s
            write = (write + 1) % capacity
        }
        filled = min(capacity, filled + samples.count)
    }

    /// The newest `count` samples (or fewer if not filled yet), oldest first.
    public func latest(_ count: Int) -> [Float] {
        let n = min(count, filled)
        guard n > 0 else { return [] }
        let start = (write - n + capacity) % capacity
        if start + n <= capacity { return Array(buffer[start..<(start + n)]) }
        return Array(buffer[start...]) + Array(buffer[..<(start + n - capacity)])
    }

    public var count: Int { filled }

    public mutating func clear() {
        write = 0
        filled = 0
    }
}
