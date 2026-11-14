import AVFoundation
import Foundation

public enum SoundCue: Sendable, CaseIterable {
    case start, stop
}

/// The two cues for the Sounds setting, made in code: a short soft sine that glides up when a take
/// starts and down when it ends. No audio files, nothing loud (peak 0.22 of full scale, played at
/// half volume), and a 6 ms fade-in plus a smooth decay so there is no click.
public enum SoundTones {
    public static let rate = 44_100.0
    public static let peak: Float = 0.22

    public static func samples(_ cue: SoundCue) -> [Float] {
        let seconds = 0.11
        let n = Int(seconds * rate)
        let (from, to): (Double, Double) = cue == .start ? (620, 840) : (840, 560)
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / Double(n)
            phase += 2 * .pi * (from + (to - from) * t) / rate
            let attack = min(1, Double(i) / (0.006 * rate))
            let decay = pow(1 - t, 1.6)
            return Float(sin(phase) * attack * decay) * peak
        }
    }

    /// 16-bit mono WAV, ready for `AVAudioPlayer(data:)`.
    public static func wav(_ cue: SoundCue) -> Data {
        let pcm = samples(cue).map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        var d = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(pcm.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        put32(16); put16(1); put16(1); put32(UInt32(rate)); put32(UInt32(rate) * 2); put16(2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(bytes)
        for s in pcm { put16(UInt16(bitPattern: s)) }
        return d
    }
}

/// Plays the cues when the Sounds setting is on. Players are made once, on first use.
@MainActor final class SoundPlayer {
    private var players: [SoundCue: AVAudioPlayer] = [:]

    func play(_ cue: SoundCue) {
        if players[cue] == nil {
            let player = try? AVAudioPlayer(data: SoundTones.wav(cue))
            player?.volume = 0.5
            player?.prepareToPlay()
            players[cue] = player
        }
        guard let player = players[cue] else { return }
        player.currentTime = 0
        player.play()
    }
}
