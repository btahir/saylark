import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark vocab build|list|eval|explain`: the names dictionary.
///
/// - `build`: rebuilds the store from every automatic source (project folders, Claude session
///   folders, Wispr's history and dictionary). Manual and blocked terms survive a rebuild.
///   `--before YYYY-MM-DD` ignores evidence from that day on (for honest evals).
/// - `list`: terms with state, sightings, sources, heard-as forms and projects.
/// - `eval <manifest.json>`: replays each take through the streaming windows, corrects every
///   window, and scores names (term recall, false insertions) and WER for each config.
/// - `explain <manifest.json> <id>` or `explain <file.wav>`: what changed in one clip, and why.
enum VocabCommand {
    static func storeURL(_ args: Arguments) -> URL {
        args.value("store").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? VocabularyStore.defaultURL
    }

    static func run(_ args: Arguments) async throws {
        switch args.positional.first {
        case "build": try build(args)
        case "list": try list(args)
        case "eval": try await eval(args)
        case "explain": try await explain(args)
        default: throw CLIError("usage: saylark vocab build|list|eval|explain (see saylark help)")
        }
    }

    // MARK: - build

    static func build(_ args: Arguments) throws {
        let store = try VocabularyStore(url: storeURL(args))
        // Every source is opt-in: nothing outside the store is read unless asked for.
        // --projects DIR: a folder whose subfolders are your projects.
        // --sessions (or --claude DIR): project folders from your Claude Code session logs.
        // --with-wispr (or --wispr FILE): a one-time import from Wispr Flow's local database.
        let projects = args.value("projects").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let claudePath = args.value("claude") ?? (args.flag("sessions") ? "~/.claude/projects" : nil)
        let claude = claudePath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let before = try args.value("before").map(parseDay)
        var input = VocabularyBuilder.Input(projectsRoot: projects)
        input.before = before
        input.now = before ?? Date()

        let t0 = ContinuousClock.now
        let sessions = claude.map { SessionFolders.load(root: $0) } ?? SessionFolders(marks: [])
        let marks = before.map { b in sessions.marks.filter { $0.time < b } } ?? sessions.marks
        let scoped = SessionFolders(marks: marks)
        input.sessionFolders = scoped.folders
        input.projectAt = { @Sendable t, app in scoped.folder(at: t, app: app) }
        log("sessions: \(marks.count) human messages in \(scoped.folders.count) folders (\(fmt(t0.msSince)) ms)")

        if args.flag("with-wispr") || args.value("wispr") != nil {
            let url = args.value("wispr").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? WisprVocabularyReader.defaultURL
            if FileManager.default.isReadableFile(atPath: url.path) {
                let reader = try WisprVocabularyReader(databaseURL: url)
                input.wisprHistory = try reader.history(before: before)
                input.wisprDictionary = try reader.dictionary()
                log("Wispr: \(input.wisprHistory.count) takes, \(input.wisprDictionary.count) dictionary entries")
            }
        }
        let common = CommonWords.system()
        let old = try store.load()
        var book = VocabularyBook()
        let report = VocabularyBuilder.build(into: &book, input, common: common)
        book.carryOver(from: old)
        book.refresh(now: input.now)
        try store.save(book)
        try store.setMeta("builtAt", ISO8601DateFormatter().string(from: Date()))
        try store.setMeta("ordinaryWords", report.ordinaryWords.joined(separator: "\n"))
        try store.setMeta("evidenceBefore", before.map { ISO8601DateFormatter().string(from: $0) } ?? "")
        print(report)
        print("live \(book.live.count), candidates \(book.terms.filter { $0.state == .candidate }.count), retired \(book.terms.filter { $0.state == .retired }.count), blocked \(book.terms.filter { $0.state == .blocked }.count)")
        print("wrote \(store.url.path) in \(fmt(t0.msSince)) ms")
    }

    static func parseDay(_ s: String) throws -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { throw CLIError("bad date \(s), want YYYY-MM-DD") }
        return d
    }

    // MARK: - list

    static func list(_ args: Arguments) throws {
        let book = try VocabularyStore(url: storeURL(args)).load()
        let state = args.value("state")
        let terms = book.terms.filter { t in
            if let state { return t.state.rawValue == state }
            return args.flag("all") || t.state == .live
        }
        .sorted { VocabularyBook.score($0, now: Date()) > VocabularyBook.score($1, now: Date()) }
        for t in terms {
            let aliases = t.aliases.prefix(4).map { "\($0.form)×\($0.count)" }.joined(separator: ", ")
            var line = "\(t.spelling)\t\(t.state.rawValue)\t\(t.sightings)\t\(t.sources.map(\.rawValue).joined(separator: "+"))"
            if !aliases.isEmpty { line += "\theard: \(aliases)" }
            if !t.projects.isEmpty { line += "\tprojects: \(t.projects.prefix(4).joined(separator: ","))" }
            if t.isCommonWord { line += "\t(common word)" }
            if let n = t.note { line += "\t[\(n)]" }
            print(line)
        }
        log("\(terms.count) of \(book.terms.count) terms")
    }

    // MARK: - eval

    struct Take {
        let id: String
        let wav: String
        let duration: Double
        let app: String?
        let ts: Double?
        let split: String?
        let reference: String
        let wisprASR: String?
    }

    static func loadManifest(_ url: URL, ref: String) throws -> [Take] {
        guard let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else { throw CLIError("bad manifest") }
        return rows.compactMap { r in
            guard let id = r["id"] as? String, let wav = r["wav"] as? String, let reference = r[ref] as? String else { return nil }
            return Take(
                id: id, wav: wav, duration: r["duration"] as? Double ?? 0, app: r["app"] as? String, ts: r["ts"] as? Double,
                split: r["split"] as? String, reference: reference, wisprASR: r["wispr_asr"] as? String)
        }
    }

    /// One take's windows: boundaries from `StreamingTranscriber` (simulated pace, default config)
    /// and its tokens, so the corrector sees exactly the windows the live path would.
    struct CachedTake: Codable {
        let id: String
        let windows: [Window]
        struct Window: Codable {
            let start: Double
            let end: Double
            let transcript: Transcript
        }
    }

    static func windows(of samples: [Float], recognizer: Recognizer, voice: VoiceActivity) async throws -> [CachedTake.Window] {
        let streaming = StreamingTranscriber(recognizer: recognizer, voice: voice, config: StreamingTranscriber.Config())
        let chunk = 1600
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let end = min(samples.count, start + chunk)
            try await streaming.append(Array(samples[start..<end]))
            await streaming.waitForWindows()
        }
        let out = try await streaming.finish()
        let duration = Double(samples.count) / 16_000
        return out.windows.enumerated().map { i, w in
            let end = i == out.windows.count - 1 ? duration : w.end
            let words = out.transcript.words.filter { $0.start >= w.start - 0.001 && ($0.start < end || i == out.windows.count - 1) }
            let tokens = out.transcript.tokens.filter { $0.start >= w.start - 0.001 && ($0.start < end || i == out.windows.count - 1) }
            return CachedTake.Window(start: w.start, end: end, transcript: Transcript(text: words.map(\.text).joined(separator: " "), words: words, tokens: tokens))
        }
    }

    struct EvalConfig {
        var name: String
        var corrector: VocabularyCorrector.Config
        var context: Bool
    }

    /// Config list: `--configs file.json` (array of flat objects: name, mode, termLimit, context,
    /// confidence, minAliasCount, soundAlike, soundMin, spellingMin, ctcMinSimilarity, ctcCbw,
    /// ctcSpotterRescue, ctcGuard, ctcGuardConfidence), else one config from the same flags.
    static func configs(_ args: Arguments) throws -> [EvalConfig] {
        var raw: [[String: Any]] = []
        if let path = args.value("configs") {
            raw = (try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))) as? [[String: Any]]) ?? []
        } else {
            var one: [String: Any] = ["name": args.value("mode") ?? "swap"]
            for key in ["mode", "termLimit", "confidence", "minAliasCount", "soundMin", "spellingMin", "ctcMinSimilarity", "ctcCbw", "ctcGuardConfidence"] {
                if let v = args.value(key) { one[key] = Double(v) ?? v }
            }
            for key in ["context", "ctcSpotterRescue"] where args.flag(key) { one[key] = true }
            for key in ["soundAlike", "ctcGuard"] where args.flag("no-\(key)") { one[key] = false }
            raw = [one]
        }
        return try raw.map(parseConfig)
    }

    static func parseConfig(_ r: [String: Any]) throws -> EvalConfig {
        var c = VocabularyCorrector.Config()
        func num(_ k: String) -> Double? { (r[k] as? NSNumber)?.doubleValue ?? (r[k] as? String).flatMap(Double.init) }
        func bool(_ k: String) -> Bool? { (r[k] as? NSNumber)?.boolValue }
        if let m = r["mode"] as? String {
            guard let mode = VocabularyCorrector.Mode(rawValue: m) else { throw CLIError("bad mode \(m)") }
            c.mode = mode
        }
        if let v = num("termLimit") { c.termLimit = Int(v) }
        if let v = num("confidence") { c.swap.confidence = Float(v) }
        if let v = num("minAliasCount") { c.swap.minAliasCount = Int(v) }
        if let v = num("soundMin") { c.swap.soundMin = v }
        if let v = num("spellingMin") { c.swap.spellingMin = v }
        if let v = bool("soundAlike") { c.swap.soundAlike = v }
        if let v = bool("learnedAliases") { c.swap.learnedAliases = v }
        if let v = bool("splitNumbers") { c.swap.splitNumbers = v }
        if let v = num("ctcMinSimilarity") { c.ctcMinSimilarity = Float(v) }
        if let v = num("ctcCbw") { c.ctcCbw = Float(v) }
        if let v = bool("ctcSpotterRescue") { c.ctcSpotterRescue = v }
        if let v = bool("ctcGuard") { c.ctcGuard = v }
        if let v = num("ctcGuardConfidence") { c.ctcGuardConfidence = Float(v) }
        return EvalConfig(name: r["name"] as? String ?? c.mode.rawValue, corrector: c, context: bool("context") ?? false)
    }

    struct ConfigResult: Codable {
        var name: String
        var takes = 0
        var audioSeconds = 0.0
        var all = TermRecall.Tally()
        var own = TermRecall.Tally()
        var wer = 0.0
        var changes = 0
        var vetoed = 0
        var msPerAudioSecond = 0.0
        var tailP50 = 0.0
        var tailP95 = 0.0
        var tailMax = 0.0
        var log: [String] = []
    }

    static func eval(_ args: Arguments) async throws {
        let manifestURL = URL(fileURLWithPath: try args.requirePositional(1, "manifest"))
        let base = manifestURL.deletingLastPathComponent()
        let refField = args.value("ref") ?? "reference"
        var takes = try loadManifest(manifestURL, ref: refField)
        if let split = args.value("split") { takes = takes.filter { $0.split == split } }
        if let n = args.value("limit").flatMap(Int.init) { takes = Array(takes.prefix(n)) }
        let targetsURL = args.value("targets").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? base.appendingPathComponent("targets.json")
        var allTargets: [String] = [], ownTargets: Set<String> = []
        if let t = try? JSONSerialization.jsonObject(with: Data(contentsOf: targetsURL)) as? [String: [String]] {
            allTargets = t["all"] ?? []
            ownTargets = Set(t["own"] ?? [])
        }
        let configs = try configs(args)
        let store = try VocabularyStore(url: storeURL(args))
        let terms = try store.liveTerms()
        let asOf = try store.meta("evidenceBefore").flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        log("\(takes.count) takes, \(configs.count) configs, \(terms.count) live terms, \(allTargets.count) target terms")

        let claudeRoot = URL(fileURLWithPath: ((args.value("claude") ?? "~/.claude/projects") as NSString).expandingTildeInPath)
        let sessions: SessionFolders? = configs.contains(where: \.context) ? SessionFolders.load(root: claudeRoot) : nil

        // Windows cache: ASR runs once per take across all evals.
        let cacheURL = URL(fileURLWithPath: ((args.value("cache") ?? base.appendingPathComponent("asr-cache.jsonl").path) as NSString).expandingTildeInPath)
        var cache: [String: CachedTake] = [:]
        if let text = try? String(contentsOf: cacheURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                if let c = try? JSONDecoder().decode(CachedTake.self, from: Data(line.utf8)) { cache[c.id] = c }
            }
        }
        var recognizer: Recognizer?, voice: VoiceActivity?
        if takes.contains(where: { cache[$0.id] == nil }) {
            recognizer = try await Recognizer.load()
            voice = try await VoiceActivity.load()
        }
        let common = try store.commonWords()
        var correctors: [VocabularyCorrector] = []
        let seedConfig = configs.first { $0.corrector.mode == .ctc || $0.corrector.mode == .both }?.corrector ?? configs[0].corrector
        let seed = try await VocabularyCorrector.load(terms: terms, common: common, config: seedConfig)
        for c in configs { correctors.append(try await seed.with(config: c.corrector)) }
        let needsCTC = configs.contains { $0.corrector.mode == .ctc || $0.corrector.mode == .both }
        let ctcSource = correctors.first { $0.config.mode == .ctc || $0.config.mode == .both }

        var results = configs.map { ConfigResult(name: $0.name) }
        var baseline = ConfigResult(name: "parakeet (no correction)")
        var wisprRow = ConfigResult(name: "wispr asr")
        var recallAll = configs.map { _ in TermRecall(terms: allTargets) }
        var baseRecall = TermRecall(terms: allTargets), wisprRecall = TermRecall(terms: allTargets)
        var wer = configs.map { _ in WordErrorTally() }
        var baseWER = WordErrorTally(), wisprWER = WordErrorTally()
        var tails = configs.map { _ in [Double]() }
        var totalMs = configs.map { _ in 0.0 }
        var audioSeconds = 0.0
        var cacheOut: FileHandle?
        if takes.contains(where: { cache[$0.id] == nil }) {
            if !FileManager.default.fileExists(atPath: cacheURL.path) { FileManager.default.createFile(atPath: cacheURL.path, contents: nil) }
            cacheOut = try FileHandle(forWritingTo: cacheURL)
            try cacheOut?.seekToEnd()
        }
        let encoder = JSONEncoder()

        for (n, take) in takes.enumerated() {
            let samples = try AudioFile.load(base.appendingPathComponent(take.wav))
            let seconds = Double(samples.count) / 16_000
            audioSeconds += seconds
            var cached = cache[take.id]
            if cached == nil, let recognizer, let voice {
                cached = CachedTake(id: take.id, windows: try await windows(of: samples, recognizer: recognizer, voice: voice))
                if let cacheOut, let c = cached { cacheOut.write(try encoder.encode(c) + Data("\n".utf8)) }
            }
            guard let cached else { continue }
            let baseText = Transcript.joined(cached.windows.map(\.transcript)).text
            baseRecall.add(reference: take.reference, hypothesis: baseText)
            baseWER.add(reference: take.reference, hypothesis: baseText)
            if let w = take.wisprASR {
                wisprRecall.add(reference: take.reference, hypothesis: w)
                wisprWER.add(reference: take.reference, hypothesis: w)
            }
            // CTC encoder once per window, shared by every CTC config.
            var evidence: [VocabularyCorrector.AcousticEvidence?] = []
            var slices: [[Float]] = []
            for w in cached.windows {
                let a = max(0, min(samples.count, Int(w.start * 16_000))), b = max(a, min(samples.count, Int(w.end * 16_000)))
                let slice = Array(samples[a..<b])
                slices.append(slice)
                evidence.append(needsCTC ? await ctcSource?.acousticEvidence(slice) : nil)
            }
            let folder = sessions?.folder(at: Date(timeIntervalSince1970: take.ts ?? 0), app: take.app)
            for (ci, cfg) in configs.enumerated() {
                let context = cfg.context ? VocabularyContext(appBundleID: take.app, projectFolder: folder) : .none
                var parts: [Transcript] = []
                var takeMs = 0.0, lastMs = 0.0
                for (wi, w) in cached.windows.enumerated() {
                    let usesCTC = cfg.corrector.mode == .ctc || cfg.corrector.mode == .both
                    let r = await correctors[ci].correct(
                        w.transcript, samples: slices[wi], timeOffset: w.start, context: context, now: asOf,
                        evidence: usesCTC ? evidence[wi] : nil)
                    parts.append(r.transcript)
                    let ms = r.ctcMs + r.swapMs + (usesCTC ? evidence[wi]?.ms ?? 0 : 0)
                    takeMs += ms
                    lastMs = ms
                    results[ci].changes += r.changes.count
                    results[ci].vetoed += r.vetoed.count
                    for c in r.changes {
                        let refHas = TermRecall(terms: [c.replacement])
                        var probe = refHas
                        let t = probe.add(reference: take.reference, hypothesis: c.replacement)[c.replacement]
                        let verdict = (t?.reference ?? 0) > 0 ? "ok?" : "WRONG"
                        results[ci].log.append("\(take.id)\t\(c.rule.rawValue)\t\(c.original) -> \(c.replacement)\t\(verdict)\t\(c.detail)")
                    }
                    for v in r.vetoed { results[ci].log.append("\(take.id)\tvetoed\t\(v.original) -> \(v.replacement)\t\(v.detail)") }
                }
                totalMs[ci] += takeMs
                tails[ci].append(lastMs)
                let text = Transcript.joined(parts).text
                recallAll[ci].add(reference: take.reference, hypothesis: text)
                wer[ci].add(reference: take.reference, hypothesis: text)
            }
            if (n + 1) % 50 == 0 { log("\(n + 1)/\(takes.count)") }
        }
        try cacheOut?.close()

        func finish(_ r: inout ConfigResult, _ rec: TermRecall, _ w: WordErrorTally) {
            r.takes = takes.count
            r.audioSeconds = audioSeconds
            r.all = rec.total()
            r.own = rec.total(ownTargets)
            r.wer = w.rate
        }
        finish(&baseline, baseRecall, baseWER)
        finish(&wisprRow, wisprRecall, wisprWER)
        for i in results.indices {
            finish(&results[i], recallAll[i], wer[i])
            results[i].msPerAudioSecond = totalMs[i] / max(1, audioSeconds)
            results[i].tailP50 = percentile(tails[i], 0.5)
            results[i].tailP95 = percentile(tails[i], 0.95)
            results[i].tailMax = tails[i].max() ?? 0
        }
        let rows = [wisprRow, baseline] + results
        print(table(rows, split: args.value("split") ?? "all"))
        if args.flag("per-term") {
            for term in allTargets {
                let b = baseRecall.byTerm[term] ?? TermRecall.Tally()
                guard b.reference > 0 || b.hypothesis > 0 else { continue }
                var line = "\(term): ref \(b.reference) base \(b.correct)/fi \(b.falseInsertions) wispr \((wisprRecall.byTerm[term] ?? .init()).correct)"
                for (i, r) in recallAll.enumerated() {
                    let t = r.byTerm[term] ?? TermRecall.Tally()
                    line += " | \(results[i].name) \(t.correct)/fi \(t.falseInsertions)"
                }
                print(line)
            }
        }
        if let out = args.value("out") {
            try writeJSON(rows, to: URL(fileURLWithPath: (out as NSString).expandingTildeInPath))
            log("wrote \(out)")
        }
    }

    static func table(_ rows: [ConfigResult], split: String) -> String {
        func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "-" : fmt(Double(a) / Double(b) * 100, 1) + "%" }
        var s = "split: \(split)\n\n| method | takes | term recall | own-name recall | lenient recall | false insertions (own) | WER | changes (vetoed) | ms per audio s | tail window p50 / p95 / max ms |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for r in rows {
            s += "| \(r.name) | \(r.takes) | \(r.all.correct)/\(r.all.reference) = \(pct(r.all.correct, r.all.reference)) | \(r.own.correct)/\(r.own.reference) = \(pct(r.own.correct, r.own.reference)) | \(pct(r.all.lenientCorrect, r.all.reference)) | \(r.all.falseInsertions) (\(r.own.falseInsertions)) | \(fmt(r.wer * 100, 2))% | \(r.changes) (\(r.vetoed)) | \(fmt(r.msPerAudioSecond, 2)) | \(fmt(r.tailP50, 1)) / \(fmt(r.tailP95, 1)) / \(fmt(r.tailMax, 1)) |\n"
        }
        return s
    }

    // MARK: - explain

    static func explain(_ args: Arguments) async throws {
        let target = try args.requirePositional(1, "manifest.json and id, or a wav file")
        var samples: [Float]
        var reference: String?
        var context = VocabularyContext.none
        if target.hasSuffix(".json") {
            let id = try args.requirePositional(2, "take id")
            let url = URL(fileURLWithPath: target)
            guard let take = try loadManifest(url, ref: args.value("ref") ?? "reference").first(where: { $0.id == id }) else { throw CLIError("no take \(id)") }
            samples = try AudioFile.load(url.deletingLastPathComponent().appendingPathComponent(take.wav))
            reference = take.reference
            if args.flag("context") {
                let sessions = SessionFolders.load(root: URL(fileURLWithPath: ("~/.claude/projects" as NSString).expandingTildeInPath))
                context = VocabularyContext(appBundleID: take.app, projectFolder: sessions.folder(at: Date(timeIntervalSince1970: take.ts ?? 0), app: take.app))
            }
        } else {
            samples = try AudioFile.load(URL(fileURLWithPath: target))
        }
        let cfg = try parseConfig(["mode": args.value("mode") ?? "both"].merging(
            ["confidence": args.value("confidence") as Any, "termLimit": args.value("termLimit") as Any].compactMapValues { $0 as? String }) { a, _ in a })
        let store = try VocabularyStore(url: storeURL(args))
        let corrector = try await VocabularyCorrector.load(terms: try store.liveTerms(), common: try store.commonWords(), config: cfg.corrector)
        let recognizer = try await Recognizer.load()
        let voice = try await VoiceActivity.load()
        let windows = try await windows(of: samples, recognizer: recognizer, voice: voice)
        if let folder = context.projectFolder { print("context: project \(folder)") }
        var parts: [Transcript] = []
        for (i, w) in windows.enumerated() {
            let a = Int(w.start * 16_000), b = min(samples.count, Int(w.end * 16_000))
            let r = await corrector.correct(w.transcript, samples: Array(samples[a..<max(a, b)]), timeOffset: w.start, context: context)
            print("window \(i + 1): \(fmt(w.start, 1))–\(fmt(w.end, 1)) s, \(r.termsUsed) terms, ctc \(fmt(r.ctcMs, 1)) ms, swap \(fmt(r.swapMs, 2)) ms")
            print("  heard: \(w.transcript.text)")
            for c in r.changes { print("  \(c.rule.rawValue): \"\(c.original)\" -> \"\(c.replacement)\" (\(c.detail))") }
            for v in r.vetoed { print("  vetoed: \"\(v.original)\" -> \"\(v.replacement)\" (\(v.detail))") }
            let unsure = w.transcript.words.filter { $0.confidence < cfg.corrector.swap.confidence }.map { "\($0.text) \(fmt(Double($0.confidence), 2))" }
            if !unsure.isEmpty { print("  unsure words: \(unsure.joined(separator: ", "))") }
            parts.append(r.transcript)
        }
        print("final: \(Transcript.joined(parts).text)")
        if let reference { print("reference: \(reference)") }
    }
}
