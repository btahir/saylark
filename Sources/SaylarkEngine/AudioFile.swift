import FluidAudio
import Foundation

/// Reads audio files into 16 kHz mono Float32, the format every Saylark engine piece uses.
public enum AudioFile {
    public static func load(_ url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}
