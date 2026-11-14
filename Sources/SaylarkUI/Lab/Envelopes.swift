import AVFoundation
import Foundation
import SaylarkCore

/// Recorded voice envelopes for the lab: computed offline from the eval clips (no playback, no mic)
/// and stored as JSON in data/envelopes/, which is gitignored.
public enum EnvelopeStore {
    /// Eval clips used by the lab, chosen for a spread of lengths and plain content.
    public static let clipIDs = [
        "c6915b41-60ed-424f-a4ec-7d6a8f0e1fad",   // 1.4 s
        "6ebe302d", "0b8cbc84", "b3e4116a",       // about 3 s
        "1ddab0d6", "782f3b78",                   // 6-7 s
        "083e94f8", "3f995059",                   // 12-14 s
        "77930940", "7150c599",                   // 22-23 s
    ]

    /// Reads the eval manifest, computes a 120 Hz envelope per chosen clip and writes `<id>.json`.
    /// Returns one summary line per clip.
    public static func extract(manifest: URL, outDir: URL) throws -> [String] {
        struct Entry: Decodable { let id: String; let wav: String; let wispr_asr: String; let duration: Double }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifest))
        let base = manifest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var lines: [String] = []
        for prefix in clipIDs {
            guard let e = entries.first(where: { $0.id.hasPrefix(prefix) }) else { lines.append("missing \(prefix)"); continue }
            let (samples, rate) = try readMono(base.appendingPathComponent(e.wav))
            var env = VoiceEnvelope.compute(id: String(e.id.prefix(8)), samples: samples, sampleRate: rate)
            env.text = e.wispr_asr
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(Rounded(env)).write(to: outDir.appendingPathComponent("\(env.id).json"))
            let dbs = env.rms.map(\.dBFS).sorted()
            let floor = dbs[dbs.count / 20], loud = dbs[dbs.count * 19 / 20]
            lines.append(String(format: "%@  %.2fs  frames %d  rms p5 %.1f dB  p95 %.1f dB  peak max %.1f dB",
                                env.id, env.duration, env.rms.count, floor, loud, env.peak.max()?.dBFS ?? -120))
        }
        return lines
    }

    /// Loads every envelope in `dir`, keyed by its 8-character id.
    public static func load(from dir: URL) -> [String: VoiceEnvelope] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [String: VoiceEnvelope] = [:]
        for f in files where f.pathExtension == "json" {
            if let d = try? Data(contentsOf: f), let e = try? JSONDecoder().decode(VoiceEnvelope.self, from: d) { out[e.id] = e }
        }
        return out
    }

    private static func readMono(_ url: URL) throws -> ([Float], Double) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else { return ([], 16000) }
        try file.read(into: buf)
        let n = Int(buf.frameLength)
        guard let ch = buf.floatChannelData else { return ([], file.processingFormat.sampleRate) }
        return (Array(UnsafeBufferPointer(start: ch[0], count: n)), file.processingFormat.sampleRate)
    }

    /// Envelope with values rounded to 5 decimals, so the JSON stays small.
    private struct Rounded: Encodable {
        let e: VoiceEnvelope
        init(_ e: VoiceEnvelope) { self.e = e }
        enum K: String, CodingKey { case id, rate, rms, peak, text }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: K.self)
            try c.encode(e.id, forKey: .id)
            try c.encode(e.rate, forKey: .rate)
            try c.encode(e.rms.map { ($0 * 1e5).rounded() / 1e5 }, forKey: .rms)
            try c.encode(e.peak.map { ($0 * 1e5).rounded() / 1e5 }, forKey: .peak)
            try c.encodeIfPresent(e.text, forKey: .text)
        }
    }
}
