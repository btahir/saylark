import Foundation

/// A recorded voice envelope: RMS and peak per frame at a fixed rate (120 Hz), linear 0...1.
/// The lab drives the pill with these instead of a live mic.
public struct VoiceEnvelope: Sendable, Codable, Equatable {
    public var id: String
    public var rate: Double
    public var rms: [Float]
    public var peak: [Float]
    /// Transcript, used only to fake live words in the lab. Lives in data/ (never committed).
    public var text: String?

    public init(id: String, rate: Double, rms: [Float], peak: [Float], text: String? = nil) {
        self.id = id
        self.rate = rate
        self.rms = rms
        self.peak = peak
        self.text = text
    }

    public var duration: Double { Double(rms.count) / rate }

    /// RMS at `time` seconds, linearly interpolated. Zero outside the clip.
    public func rms(at time: Double) -> Float { sample(rms, at: time) }
    public func peak(at time: Double) -> Float { sample(peak, at: time) }

    private func sample(_ values: [Float], at time: Double) -> Float {
        let x = time * rate
        guard x >= 0, !values.isEmpty else { return 0 }
        let i = Int(x)
        guard i < values.count - 1 else { return i < values.count ? values[i] : 0 }
        let f = Float(x - Double(i))
        return values[i] + (values[i + 1] - values[i]) * f
    }

    /// A flat envelope at a fixed level, for no-signal scenes. `db` is dBFS.
    public static func constant(id: String, seconds: Double, db: Double, rate: Double = 120) -> VoiceEnvelope {
        let v = Float(pow(10, db / 20))
        let n = Int(seconds * rate)
        return VoiceEnvelope(id: id, rate: rate, rms: Array(repeating: v, count: n), peak: Array(repeating: v * 1.4, count: n))
    }

    /// Computes the envelope from mono samples. Each frame covers `1/rate` seconds; RMS uses a window
    /// of two frames centred on the frame so the curve is smooth without lagging.
    public static func compute(id: String, samples: [Float], sampleRate: Double, rate: Double = 120) -> VoiceEnvelope {
        let hop = sampleRate / rate
        let frames = Int(Double(samples.count) * rate / sampleRate + 1e-9)
        var rms = [Float](repeating: 0, count: frames)
        var peak = [Float](repeating: 0, count: frames)
        samples.withUnsafeBufferPointer { s in
            for f in 0..<frames {
                let centre = (Double(f) + 0.5) * hop
                let lo = max(0, Int(centre - hop)), hi = min(s.count, Int(centre + hop))
                var sum: Float = 0, top: Float = 0
                for i in lo..<hi {
                    let v = s[i]
                    sum += v * v
                    top = max(top, abs(v))
                }
                rms[f] = hi > lo ? (sum / Float(hi - lo)).squareRoot() : 0
                peak[f] = top
            }
        }
        return VoiceEnvelope(id: id, rate: rate, rms: rms, peak: peak)
    }
}

/// Turns raw RMS into the 0...1 level the voice visual shows: dB scale, fast attack, slower release.
/// Same ballistics as a VU-style meter, so the visual follows syllables without flicker.
public struct LevelMeter: Sendable {
    /// dBFS that maps to 0 and to 1.
    public var floorDB: Double = -54
    public var ceilingDB: Double = -22
    /// Time constants in seconds.
    public var attack: Double = 0.018
    public var release: Double = 0.07
    public private(set) var level: Double = 0

    public init() {}

    /// Maps linear RMS to 0...1 without smoothing.
    public func normalized(_ rms: Float) -> Double {
        let db = 20 * log10(max(Double(rms), 1e-7))
        return min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
    }

    public mutating func update(rms: Float, dt: Double) -> Double {
        let target = normalized(rms)
        let tau = target > level ? attack : release
        level += (target - level) * (1 - exp(-dt / tau))
        return level
    }

    public mutating func reset() { level = 0 }
}

public extension Float {
    /// Linear amplitude to dBFS.
    var dBFS: Double { 20 * log10(max(Double(self), 1e-7)) }
}
