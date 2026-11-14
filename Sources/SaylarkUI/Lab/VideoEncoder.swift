import Foundation

/// Pipes raw BGRA frames into ffmpeg (H.264, BT.709, yuv420p). Frames never touch the disk.
/// Run the whole render under research/heavy.sh; this spawns ffmpeg directly so it doesn't take a
/// second slot.
public final class VideoEncoder {
    private let process = Process()
    private let pipe = Pipe()
    public let output: URL

    public init(output: URL, width: Int, height: Int, fps: Double) throws {
        self.output = output
        process.executableURL = URL(fileURLWithPath: VideoEncoder.ffmpegPath)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pix_fmt", "bgra", "-s", "\(width)x\(height)", "-r", String(fps), "-i", "-",
            "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
            "-c:v", "libx264", "-preset", "medium", "-crf", "15", "-tune", "animation",
            "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1", "-color_range", "tv",
            "-movflags", "+faststart", output.path,
        ]
        process.standardInput = pipe
        try process.run()
    }

    /// False once ffmpeg has stopped taking frames. `FileHandle.write(_:)` raises an Objective-C
    /// exception (a crash) when the pipe is closed, so this uses the throwing call.
    @discardableResult
    public func write(_ frame: Data) -> Bool {
        guard !broken else { return false }
        do { try pipe.fileHandleForWriting.write(contentsOf: frame) } catch { broken = true }
        return !broken
    }

    private var broken = false

    /// Closes the stream and waits for ffmpeg. Returns true on success.
    @discardableResult
    public func finish() -> Bool {
        try? pipe.fileHandleForWriting.close()
        process.waitUntilExit()
        return !broken && process.terminationStatus == 0
    }

    /// Writes a slow-motion copy: the same frames played at `fps / factor`.
    public static func slowMotion(from input: URL, to output: URL, factor: Int) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpegPath)
        p.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path,
                       "-vf", "setpts=\(factor)*PTS", "-r", "30", "-c:v", "libx264", "-preset", "medium", "-crf", "15",
                       "-tune", "animation", "-pix_fmt", "yuv420p",
                       "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "iec61966-2-1",
                       "-movflags", "+faststart", output.path]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    static var ffmpegPath: String {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffmpeg"
    }
}
