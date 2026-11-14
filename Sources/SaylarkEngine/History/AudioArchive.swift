import AVFoundation
import Foundation

/// Saves take audio as AAC in an .m4a (AVFoundation's encoder, no extra dependency).
/// 16 kHz mono AAC-LC with the encoder's default rate: measured about 44 kbit/s (5.5 KB per second).
/// Asking for 24 or 32 kbit/s does not go lower at 16 kHz (32 gave 52 kbit/s).
public enum AudioArchive {
    /// Writes 16 kHz mono samples to `url`.
    public static func writeM4A(_ samples: [Float], to url: URL, sampleRate: Double = 16_000) throws {
        let file = try open(url, sampleRate: sampleRate)
        try append(samples, to: file)
    }

    /// Encodes a take spool (raw Float32, see `TakeSpool`) to `url`, a block at a time, so a long
    /// take is never held in memory whole.
    public static func writeM4A(spool: URL, to url: URL, sampleRate: Double = 16_000) throws {
        let file = try open(url, sampleRate: sampleRate)
        try TakeSpool.read(spool, block: 16_384) { try append($0, to: file) }
    }

    private static func open(_ url: URL, sampleRate: Double) throws -> AVAudioFile {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private static func append(_ samples: [Float], to file: AVAudioFile) throws {
        let block = 16_384
        var offset = 0
        while offset < samples.count {
            let n = min(block, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            samples.withUnsafeBufferPointer { src in
                buffer.floatChannelData![0].update(from: src.baseAddress! + offset, count: n)
            }
            try file.write(from: buffer)
            offset += n
        }
    }

    /// Relative path for a take's audio: `audio/YYYY-MM/<id>.m4a`.
    public static func relativePath(id: UUID, startedAt: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: startedAt)
        return String(format: "audio/%04d-%02d/%@.m4a", c.year ?? 0, c.month ?? 0, id.uuidString)
    }
}
