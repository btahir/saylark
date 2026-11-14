import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark bench <manifest.json>`: replays each eval clip through `StreamingTranscriber` and
/// measures release → final text, the time after the last audio chunk. Also runs each clip in one
/// pass for comparison, and scores both against Wispr's ASR text and what was pasted.
///
/// Pacing:
/// - `realtime`: chunks are enqueued on a wall clock at real speed, like live capture.
/// - `simulated`: chunks are appended as fast as voice detection runs, and the bench waits for
///   every closed window to finish before the next chunk, except in the last `--guard` seconds
///   (default 0.3 s), where windows may still be running at release. Window boundaries are the
///   same as in real time (the planner only sees samples), and the release state is no better than
///   real time as long as a window takes under 0.3 s to transcribe.
/// Counts live-word updates from the transcriber's callback.
final class WordCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// User + system CPU time of this process, ms.
func processCPUms() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
    return ms(usage.ru_utime) + ms(usage.ru_stime)
}

enum BenchCommand {
    struct Clip: Decodable {
        let id: String
        let bucket: String
        let duration: Double
        let wav: String
        let wispr_asr: String
        let pasted: String?
    }

    struct Row: Codable {
        let id: String
        let bucket: String
        let duration: Double
        var text: String = ""
        var latency_ms: Double?
        var stream_text: String = ""
        var release_ms: Double = 0
        var feed_ms: Double = 0
        var windows: [StreamingTranscriber.Window] = []
        var vocab_text: String?
        var vocab_applied: [String]?
        var vocab_ms: Double?
        var live: StreamingTranscriber.LiveStats?
        /// Live words updates sent to the pill.
        var word_updates: Int?
        /// Process CPU time while feeding (voice detection, partial decoding on the CPU side), ms.
        var feed_cpu_ms: Double?
    }

    struct Summary: Codable {
        struct Bucket: Codable {
            let bucket: String
            let n: Int
            let release_p50: Double
            let release_p95: Double
            let release_max: Double
            let whole_p50: Double?
            let whole_p95: Double?
            let wer_stream: Double
            let wer_whole: Double?
        }
        let pace: String
        let config: String
        let clips: Int
        let buckets: [Bucket]
        let release_p95_all: Double
        let wer_stream_asr: Double
        let wer_whole_asr: Double?
        let wer_stream_pasted: Double
        let wer_stream_clean_pasted: Double
        let wer_whole_pasted: Double?
        let wer_vocab_asr: Double?
    }

    struct Report: Codable {
        let summary: Summary
        let load_ms: Double
        let clips: [Row]
    }

    static let buckets = ["short<5", "mid5-15", "long15-60", "xl60+"]

    static func run(_ args: Arguments) async throws {
        let manifestURL = URL(fileURLWithPath: try args.requirePositional(0, "manifest"))
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: manifestURL))
            .filter { b in args.value("buckets").map { $0.split(separator: ",").map(String.init).contains(b.bucket) } ?? true }
            .prefix(args.int("limit", 100_000))
        let base = manifestURL.deletingLastPathComponent()
        let pace = args.value("pace") ?? "simulated"
        let chunkSamples = args.int("chunk-ms", 100) * 16
        let guardSamples = Int(args.double("guard", 0.3) * 16_000)
        var config = StreamingTranscriber.Config()
        config.planner.minPause = args.double("min-pause", config.planner.minPause)
        config.planner.minWindow = args.double("min-window", config.planner.minWindow)
        config.planner.maxWindow = args.double("max-window", config.planner.maxWindow)
        config.planner.silenceThreshold = Float(args.double("silence", Double(config.planner.silenceThreshold)))
        config.boundaryMargin = args.double("margin", config.boundaryMargin)
        let live = args.flag("live")
        if live {
            config.partialInterval = args.double("partial-interval", 0.8)
            config.partialOnPause = !args.flag("no-pause-partials")
            config.reuseAtRelease = !args.flag("no-reuse")
        }
        let configName = "minPause=\(config.planner.minPause) window=\(config.planner.minWindow)-\(config.planner.maxWindow)s silence<\(config.planner.silenceThreshold) margin=\(config.boundaryMargin) chunk=\(chunkSamples / 16)ms"
            + (live ? " live=\(config.partialInterval)s pause=\(config.partialOnPause) reuse=\(config.reuseAtRelease)" : "")

        let loadStart = ContinuousClock.now
        let recognizer = try await Recognizer.load()
        let voice = try await VoiceActivity.load()
        let loadMs = loadStart.msSince
        var booster: VocabularyBooster?
        if let vocabPath = args.value("vocab") {
            let lines = try String(contentsOfFile: (vocabPath as NSString).expandingTildeInPath, encoding: .utf8)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
            // Line format: `Term` or `Term<TAB>alias1|alias2`.
            var terms: [String] = [], aliases: [String: [String]] = [:]
            for line in lines {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                terms.append(parts[0])
                if parts.count > 1, !args.flag("no-aliases") { aliases[parts[0]] = parts[1].split(separator: "|").map(String.init) }
            }
            booster = try await VocabularyBooster.load(terms: terms, aliases: aliases, minSimilarity: args.value("vocab-min-sim").flatMap(Float.init))
            log("vocabulary: \(terms.count) terms, \(aliases.count) with aliases")
        }
        // Warm voice detection too.
        var warm = voice.makeState()
        _ = try await voice.probability(of: [Float](repeating: 0, count: VoiceActivity.chunkSize), state: &warm)
        log("loaded in \(fmt(loadMs)) ms; pace \(pace); \(configName)")

        var rows: [Row] = []
        for clip in clips {
            let samples = try AudioFile.load(base.appendingPathComponent(clip.wav))
            var row = Row(id: clip.id, bucket: clip.bucket, duration: clip.duration)

            if !args.flag("no-whole") {
                var times: [Double] = []
                var last: Recognition?
                for _ in 0..<(clip.duration < 5 ? 3 : 1) {
                    let t = ContinuousClock.now
                    let r = try await recognizer.transcribe(samples)
                    times.append(t.msSince)
                    last = r
                }
                row.text = last!.transcript.text
                row.latency_ms = times.sorted()[times.count / 2]
                if let booster, let last {
                    let t = ContinuousClock.now
                    let r = await booster.rescore(last, samples: samples)
                    row.vocab_ms = t.msSince
                    row.vocab_text = r.text
                    row.vocab_applied = r.applied
                }
            }

            let updates = WordCounter()
            var onWords: (@Sendable ([String]) -> Void)?
            if live { onWords = { @Sendable (_: [String]) -> Void in updates.bump() } }
            let streaming = StreamingTranscriber(recognizer: recognizer, voice: voice, config: config, onWords: onWords)
            let feedStart = ContinuousClock.now
            let cpuStart = processCPUms()
            let chunkStarts = Array(stride(from: 0, to: samples.count, by: chunkSamples))
            if pace == "realtime" {
                let clock = ContinuousClock()
                let t0 = clock.now
                for (k, start) in chunkStarts.enumerated() {
                    let end = min(samples.count, start + chunkSamples)
                    // A chunk is available once its last sample has been "spoken".
                    try await clock.sleep(until: t0 + .microseconds(Int64(Double(end) / 16.0 * 1000)))
                    streaming.enqueue(Array(samples[start..<end]))
                    _ = k
                }
            } else {
                for start in chunkStarts {
                    let end = min(samples.count, start + chunkSamples)
                    try await streaming.append(Array(samples[start..<end]))
                    if end < samples.count - guardSamples { await streaming.waitForWindows() }
                }
            }
            row.feed_ms = feedStart.msSince
            row.feed_cpu_ms = processCPUms() - cpuStart
            // Diagnostic: idle this long before release (tests whether idle hardware slows the tail).
            if let gap = args.value("gap").flatMap(Double.init) { try await Task.sleep(for: .milliseconds(Int(gap * 1000))) }
            let release = ContinuousClock.now
            let out = try await streaming.finish()
            row.release_ms = release.msSince
            row.stream_text = out.transcript.text
            row.windows = out.windows
            if live {
                row.live = out.live
                row.word_updates = updates.count
            }
            rows.append(row)
            log("\(clip.bucket) \(fmt(clip.duration, 1)) s: release \(fmt(row.release_ms)) ms, \(out.windows.count) windows, whole \(row.latency_ms.map { fmt($0) } ?? "-") ms")
        }

        let summary = summarise(rows: rows, clips: Array(clips), pace: pace, config: configName)
        let report = Report(summary: summary, load_ms: loadMs, clips: rows)
        let outURL = URL(fileURLWithPath: args.value("out") ?? "data/bench/bench-\(pace).json")
        try writeJSON(report, to: outURL)
        print(markdown(summary))
        if live { print(liveMarkdown(rows)) }
        log("wrote \(outURL.path)")
    }

    /// Partial cost and release reuse, per bucket.
    static func liveMarkdown(_ rows: [Row]) -> String {
        var out = "\n| bucket | n | partials/clip | partial p50 ms | partial p95 ms | ANE busy % of audio | reused at release | waited p95 ms | CPU ms per audio s |\n|---|---|---|---|---|---|---|---|---|\n"
        for b in buckets + ["all"] {
            let rs = rows.filter { b == "all" || $0.bucket == b }
            guard !rs.isEmpty else { continue }
            let partialMs = rs.flatMap { $0.live?.partialMs ?? [] }
            let busy = rs.reduce(0) { $0 + ($1.live?.partialMs.reduce(0, +) ?? 0) } / rs.reduce(0) { $0 + $1.duration * 1000 }
            let reused = rs.filter { $0.live?.reusedAtRelease == true }.count
            let waited = rs.map { $0.live?.waitedForPartialMs ?? 0 }
            let cpu = rs.reduce(0) { $0 + ($1.feed_cpu_ms ?? 0) } / rs.reduce(0) { $0 + $1.duration }
            out += "| \(b) | \(rs.count) | \(fmt(Double(partialMs.count) / Double(rs.count), 1)) | \(fmt(percentile(partialMs, 0.5))) | \(fmt(percentile(partialMs, 0.95))) | \(fmt(busy * 100, 1)) | \(reused)/\(rs.count) | \(fmt(percentile(waited, 0.95))) | \(fmt(cpu)) |\n"
        }
        return out
    }

    static func summarise(rows: [Row], clips: [Clip], pace: String, config: String) -> Summary {
        let byId = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        var streamAsr = WordErrorTally(), wholeAsr = WordErrorTally(), streamPasted = WordErrorTally()
        var cleanPasted = WordErrorTally(), wholePasted = WordErrorTally(), vocabAsr = WordErrorTally()
        let hasWhole = rows.contains { $0.latency_ms != nil }
        let hasVocab = rows.contains { $0.vocab_text != nil }
        var buckets: [Summary.Bucket] = []
        for b in Self.buckets {
            let rs = rows.filter { $0.bucket == b }
            guard !rs.isEmpty else { continue }
            var s = WordErrorTally(), w = WordErrorTally()
            for r in rs {
                let ref = byId[r.id]!.wispr_asr
                s.add(reference: ref, hypothesis: r.stream_text)
                w.add(reference: ref, hypothesis: r.text)
            }
            let rel = rs.map(\.release_ms), whole = rs.compactMap(\.latency_ms)
            buckets.append(.init(
                bucket: b, n: rs.count, release_p50: percentile(rel, 0.5), release_p95: percentile(rel, 0.95),
                release_max: rel.max() ?? 0,
                whole_p50: whole.isEmpty ? nil : percentile(whole, 0.5), whole_p95: whole.isEmpty ? nil : percentile(whole, 0.95),
                wer_stream: s.rate, wer_whole: hasWhole ? w.rate : nil))
        }
        for r in rows {
            let c = byId[r.id]!
            streamAsr.add(reference: c.wispr_asr, hypothesis: r.stream_text)
            wholeAsr.add(reference: c.wispr_asr, hypothesis: r.text)
            if let v = r.vocab_text { vocabAsr.add(reference: c.wispr_asr, hypothesis: v) }
            if let p = c.pasted {
                streamPasted.add(reference: p, hypothesis: r.stream_text)
                cleanPasted.add(reference: p, hypothesis: Cleanup.apply(r.stream_text), dropFillers: false)
                wholePasted.add(reference: p, hypothesis: r.text)
            }
        }
        return Summary(
            pace: pace, config: config, clips: rows.count, buckets: buckets,
            release_p95_all: percentile(rows.map(\.release_ms), 0.95),
            wer_stream_asr: streamAsr.rate, wer_whole_asr: hasWhole ? wholeAsr.rate : nil,
            wer_stream_pasted: streamPasted.rate, wer_stream_clean_pasted: cleanPasted.rate,
            wer_whole_pasted: hasWhole ? wholePasted.rate : nil, wer_vocab_asr: hasVocab ? vocabAsr.rate : nil)
    }

    static func markdown(_ s: Summary) -> String {
        func pct(_ x: Double?) -> String { x.map { fmt($0 * 100, 1) + "%" } ?? "-" }
        func ms(_ x: Double?) -> String { x.map { fmt($0) } ?? "-" }
        var lines = [
            "pace: \(s.pace); \(s.config); \(s.clips) clips",
            "",
            "| bucket | n | release p50 | release p95 | release max | one-pass p50 | one-pass p95 | WER windowed | WER one-pass |",
            "|---|---|---|---|---|---|---|---|---|",
        ]
        for b in s.buckets {
            lines.append("| \(b.bucket) | \(b.n) | \(ms(b.release_p50)) | \(ms(b.release_p95)) | \(ms(b.release_max)) | \(ms(b.whole_p50)) | \(ms(b.whole_p95)) | \(pct(b.wer_stream)) | \(pct(b.wer_whole)) |")
        }
        lines.append("")
        lines.append("release p95 (all clips): \(ms(s.release_p95_all)) ms")
        lines.append("WER vs wispr_asr (no fillers): windowed \(pct(s.wer_stream_asr)), one-pass \(pct(s.wer_whole_asr))" + (s.wer_vocab_asr.map { ", one-pass + vocab \(pct($0))" } ?? ""))
        lines.append("WER vs pasted (no fillers): windowed \(pct(s.wer_stream_pasted)), windowed + Cleanup \(pct(s.wer_stream_clean_pasted)), one-pass \(pct(s.wer_whole_pasted))")
        return lines.joined(separator: "\n")
    }
}
