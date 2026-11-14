import Foundation
import SaylarkCore
import Synchronization

/// A take's audio on disk while it is being spoken, so a crash, force-quit, sleep-death or power
/// loss loses at most the last second. Raw 16 kHz mono Float32 (little-endian) in
/// `<history>/spool/<take id>.pcm`, with the take's facts in `<take id>.json` next to it.
///
/// `append` is called on the capture worker queue (never the real-time thread). It only copies into
/// a small buffer; every `flushSeconds` of audio the buffer is written by a background serial queue,
/// and the file is synced to disk about every 5 s. That is 64 KB/s of sequential writes.
///
/// The spool is also the take's only full copy of its audio: the m4a is encoded from it at the end,
/// so neither the capture nor the transcriber holds the whole take in memory.
public final class TakeSpool: @unchecked Sendable {
    /// What a recovered take needs besides its audio.
    public struct Meta: Codable, Sendable, Equatable {
        public var id: UUID
        public var startedAt: Date
        public var mode: DictationMode
        public var handsFree: Bool
        public var appBundleID: String?
        public var appName: String?

        public init(id: UUID, startedAt: Date, mode: DictationMode, handsFree: Bool = false, appBundleID: String? = nil, appName: String? = nil) {
            self.id = id
            self.startedAt = startedAt
            self.mode = mode
            self.handsFree = handsFree
            self.appBundleID = appBundleID
            self.appName = appName
        }
    }

    /// An orphaned spool found at launch.
    public struct Orphan: Sendable {
        public let meta: Meta
        public let audio: URL
        public var sampleCount: Int {
            let size = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? Int) ?? 0
            return size / MemoryLayout<Float>.size
        }
    }

    public static let flushSeconds = 1.0
    private static let syncEvery = 5

    public let audioURL: URL
    public let metaURL: URL
    private let queue = DispatchQueue(label: "saylark.spool", qos: .utility)
    private let handle: FileHandle
    private let pending = Mutex<(samples: [Float], total: Int, closed: Bool)>(([], 0, false))
    private var meta: Meta
    private var flushes = 0
    private let flushSamples: Int

    public static func folder(in history: URL) -> URL {
        history.appendingPathComponent("spool", isDirectory: true)
    }

    public init(folder: URL, meta: Meta, flushSeconds: Double = TakeSpool.flushSeconds) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        audioURL = folder.appendingPathComponent("\(meta.id.uuidString).pcm")
        metaURL = folder.appendingPathComponent("\(meta.id.uuidString).json")
        self.meta = meta
        flushSamples = max(1, Int(flushSeconds * Double(Recognizer.sampleRate)))
        try Self.write(meta, to: metaURL)
        FileManager.default.createFile(atPath: audioURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: audioURL)
    }

    /// Samples appended so far.
    public var sampleCount: Int { pending.withLock { $0.total } }

    /// Adds audio. Never waits on the disk.
    public func append(_ chunk: [Float]) {
        let full = pending.withLock { p -> [Float]? in
            guard !p.closed else { return nil }
            p.samples += chunk
            p.total += chunk.count
            guard p.samples.count >= flushSamples else { return nil }
            defer { p.samples = [] }
            return p.samples
        }
        if let full { queue.async { [self] in write(full) } }
    }

    /// Records that the take locked into hands-free.
    public func update(handsFree: Bool) {
        queue.async { [self] in
            meta.handsFree = handsFree
            try? Self.write(meta, to: metaURL)
        }
    }

    /// Writes what is left and closes the file. The spool stays on disk until `remove()`, so a crash
    /// before the take is saved still recovers it.
    public func close() async {
        let rest = pending.withLock { p -> [Float] in
            p.closed = true
            defer { p.samples = [] }
            return p.samples
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                write(rest)
                try? handle.synchronize()
                try? handle.close()
                done.resume()
            }
        }
    }

    /// Deletes the spool once the take is safely in history.
    public func remove() {
        Self.remove(audio: audioURL, meta: metaURL)
    }

    private func write(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        samples.withUnsafeBufferPointer { try? handle.write(contentsOf: Data(buffer: $0)) }
        flushes += 1
        if flushes % Self.syncEvery == 0 { try? handle.synchronize() }
    }

    // MARK: - Reading and recovery

    /// Spools left by a run that ended during a take (crash, force-quit, power loss), oldest first.
    /// `excluding` skips takes that are running now.
    public static func orphans(in folder: URL, excluding: Set<UUID> = []) -> [Orphan] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        var found: [Orphan] = []
        for name in names where name.hasSuffix(".pcm") {
            let audio = folder.appendingPathComponent(name)
            let metaURL = audio.deletingPathExtension().appendingPathExtension("json")
            guard let data = try? Data(contentsOf: metaURL), let meta = try? decoder.decode(Meta.self, from: data) else {
                // Audio with no readable facts: keep it as an unknown take rather than lose it.
                guard let id = UUID(uuidString: audio.deletingPathExtension().lastPathComponent), !excluding.contains(id) else { continue }
                let date = (try? FileManager.default.attributesOfItem(atPath: audio.path)[.creationDate] as? Date) ?? Date()
                found.append(Orphan(meta: Meta(id: id, startedAt: date, mode: .shadow), audio: audio))
                continue
            }
            guard !excluding.contains(meta.id) else { continue }
            found.append(Orphan(meta: meta, audio: audio))
        }
        return found.sorted { $0.meta.startedAt < $1.meta.startedAt }
    }

    public static func remove(audio: URL, meta: URL? = nil) {
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: meta ?? audio.deletingPathExtension().appendingPathExtension("json"))
    }

    /// Reads a spool file in blocks of `block` samples, in order. A torn last sample is ignored.
    public static func read(_ url: URL, block: Int = 16_000, _ body: ([Float]) throws -> Void) throws {
        let reader = try Reader(url)
        while let chunk = try reader.next(block) { try body(chunk) }
    }

    /// Reads a spool file a block at a time (usable from async code).
    public final class Reader {
        private let handle: FileHandle
        private var carry = Data()

        public init(_ url: URL) throws {
            handle = try FileHandle(forReadingFrom: url)
        }

        deinit { try? handle.close() }

        /// The next block of up to `count` samples, or nil at the end.
        public func next(_ count: Int) throws -> [Float]? {
            let size = MemoryLayout<Float>.size
            while carry.count < count * size {
                guard let data = try handle.read(upToCount: count * size - carry.count), !data.isEmpty else { break }
                carry.append(data)
            }
            let whole = min(carry.count, count * size) / size * size
            guard whole > 0 else { return nil }
            let chunk = carry.prefix(whole).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            carry.removeFirst(whole)
            return chunk
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    private static func write(_ meta: Meta, to url: URL) throws {
        try encoder.encode(meta).write(to: url, options: .atomic)
    }
}
