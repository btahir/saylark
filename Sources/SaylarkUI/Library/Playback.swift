import AVFoundation
import Observation
import SaylarkCore

/// Plays one take at a time in the Library and reports where it is, for the waveform and the word
/// highlight. Takes without audio (cancelled long ago, or the fake engine) still get a waveform drawn
/// from their word timings, but nothing plays.
@MainActor @Observable public final class PlaybackModel {
    public private(set) var record: DictationRecord?
    /// 0...1 level per bar.
    public private(set) var levels: [Float] = []
    public private(set) var isPlaying = false
    public private(set) var hasAudio = false
    /// The playhead in seconds. Follows the audio while playing (about 60 updates a second).
    public var position: Double = 0
    @ObservationIgnored private var audio: AVAudioPlayer?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?

    public init() {}

    public var duration: Double { audio?.duration ?? record?.duration ?? 0 }

    public var currentTime: Double { position }

    public func open(_ record: DictationRecord, url: URL?, bars: Int = 160) {
        stop()
        self.record = record
        position = 0
        audio = url.flatMap { try? AVAudioPlayer(contentsOf: $0) }
        audio?.prepareToPlay()
        hasAudio = audio != nil
        levels = Waveform.bars(from: SampleTakes.envelope(for: record), count: bars)
        loadTask?.cancel()
        if let url {
            loadTask = Task {
                let bars = await Task.detached(priority: .userInitiated) { Waveform.bars(audioURL: url, count: bars) }.value
                guard !Task.isCancelled, let bars, self.record?.id == record.id else { return }
                self.levels = bars
            }
        }
    }

    public func play() {
        guard let audio else { return }
        audio.currentTime = position
        audio.play()
        isPlaying = true
        ticker?.cancel()
        ticker = Task { [weak self] in
            while let self, self.isPlaying, !Task.isCancelled {
                guard let a = self.audio, a.isPlaying else {
                    self.isPlaying = false
                    self.position = 0
                    return
                }
                self.position = a.currentTime
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    public func togglePlay() { isPlaying ? pause() : play() }

    public func pause() {
        position = audio?.currentTime ?? position
        audio?.pause()
        isPlaying = false
        ticker?.cancel()
    }

    public func stop() {
        audio?.stop()
        isPlaying = false
        ticker?.cancel()
    }

    public func seek(to time: Double) {
        position = max(0, min(duration, time))
        audio?.currentTime = position
    }

    /// Index of the word being spoken at `time`, if any.
    public func wordIndex(at time: Double) -> Int? {
        guard let words = record?.words, !words.isEmpty else { return nil }
        return words.lastIndex { $0.start <= time + 0.03 }
    }
}

/// Downsampling audio (or an envelope) into a fixed number of bars for the slim waveform.
public enum Waveform {
    /// Peak per bar from a level envelope, normalised so the loudest bar is 1.
    public static func bars(from envelope: [Float], count: Int) -> [Float] {
        guard !envelope.isEmpty, count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let a = i * envelope.count / count, b = max(a + 1, (i + 1) * envelope.count / count)
            out[i] = envelope[a..<min(b, envelope.count)].max() ?? 0
        }
        let top = max(out.max() ?? 1, 1e-6)
        return out.map { $0 / top }
    }

    /// Reads an audio file and returns RMS bars on a dB scale (so quiet speech still shows), 0...1.
    /// Reads in chunks of about a second, so a long hands-free take never sits in memory whole.
    public static func bars(audioURL: URL, count: Int) -> [Float]? {
        guard count > 0, let file = try? AVAudioFile(forReading: audioURL, commonFormat: .pcmFormatFloat32, interleaved: false),
              file.length > 0 else { return nil }
        let total = Int(file.length)
        let chunk = AVAudioFrameCount(max(4096, Int(file.processingFormat.sampleRate)))
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return nil }
        var sums = [Double](repeating: 0, count: count), counts = [Int](repeating: 0, count: count)
        var position = 0
        while position < total {
            buf.frameLength = 0
            guard (try? file.read(into: buf, frameCount: chunk)) != nil, buf.frameLength > 0, let ch = buf.floatChannelData else { break }
            let n = Int(buf.frameLength)
            for j in 0..<n {
                let bar = min(count - 1, (position + j) * count / total)
                let v = Double(ch[0][j])
                sums[bar] += v * v
                counts[bar] += 1
            }
            position += n
        }
        return (0..<count).map { i in
            let rms = Float((sums[i] / Double(max(1, counts[i]))).squareRoot())
            return Float(max(0, min(1, (rms.dBFS + 60) / 45)))
        }
    }
}
