import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark simulate <wav>`: runs the whole engine end to end with no mic and no key hook.
/// A fake mic plays the clip in real time from Fn-down, a scripted timeline presses Fn, history
/// goes to a temp folder, and every event is printed with its time.
///
/// Scripts: `hold` (push-to-talk over the clip), `handsfree` (double-tap, stop tap 0.5 s after the
/// clip), `tap` (short tap: discarded), `chord` (Fn+key: discarded), `esc` (cancel halfway),
/// `lostup` (a hold whose Fn release the hook never hears: the engine's Fn check must end it),
/// `stop` (hands-free, then the engine is stopped halfway, as "Pause for 1 hour" does: saved).
///
/// `--unplug-after <s>`: the fake mic dies that many seconds after it opens (the take must end
/// and keep what was heard). `--mic-delay <s>`: the fake mic's start-up time.
///
/// Every take pastes into a pretend app (`ActiveSimulation`: in-memory clipboard, recorded keys,
/// scripted focus and Return tap; nothing real is touched). `--active` is accepted and changes
/// nothing (pasting used to be a mode). `--send` ends the take with
/// Return (hold: Return before the release; handsfree: Return instead of the stop tap) with send
/// on Return set to everywhere. `--no-field`: nothing editable has focus. `--no-clipboard`: the
/// clipboard can't be read without the macOS prompt. `--trigger fn|rightOption|rightCommand`.
/// `esc` pastes the cancelled take back afterwards, as the menu's Paste does.
/// `--no-paragraphs` turns paragraph breaks from pauses off.
enum SimulateCommand {
    @MainActor
    static func run(_ args: Arguments) async throws {
        let wav = URL(fileURLWithPath: try args.requirePositional(0, "wav"))
        let samples = try AudioFile.load(wav)
        let clip = Double(samples.count) / 16_000
        let script = args.value("script") ?? "hold"
        // Loading the dictionary takes about 200 ms of engine start; give the warm mic time to fill its pre-roll.
        let lead = args.value("dict") == nil ? 0.3 : 1.0
        let sendKey = args.flag("send")
        if sendKey, !["hold", "handsfree"].contains(script) { throw CLIError("--send works with hold or handsfree") }
        let trigger = try args.value("trigger").map { name -> TriggerKey in
            guard let t = TriggerKey(rawValue: name) else { throw CLIError("unknown trigger \(name)") }
            return t
        } ?? .fn
        let sim: ActiveSimulation? = ActiveSimulation(noField: args.flag("no-field"), noClipboard: args.flag("no-clipboard"))
        let tap = sim?.tap
        // The moment the take ends (trigger up, stop tap or Return), from the first press.
        var endsAt: Double? = nil
        let fn: ScriptedFnSource = switch script {
        case "hold" where sendKey:
            ScriptedFnSource([(lead, .fnDown), (lead + clip + 0.1, .returnKey), (lead + clip + 0.25, .fnUp)], returnTap: tap)
        case "handsfree" where sendKey:
            ScriptedFnSource([(lead, .fnDown), (lead + 0.08, .fnUp), (lead + 0.2, .fnDown), (lead + 0.28, .fnUp), (lead + clip + 0.5, .returnKey)],
                             returnTap: tap)
        case "hold": .hold(at: lead, for: clip + 0.15, returnTap: tap)
        case "handsfree": .handsFree(at: lead, talk: clip + 0.5, returnTap: tap)
        case "tap": .hold(at: lead, for: 0.1)
        case "chord": ScriptedFnSource([(lead, .fnDown), (lead + 0.05, .key), (lead + 0.2, .fnUp)])
        case "esc": ScriptedFnSource([(lead, .fnDown), (lead + clip / 2, .escape), (lead + clip / 2 + 0.1, .fnUp)])
        case "lostup": ScriptedFnSource([(lead, .fnDown), (lead + clip + 0.15, .fnUpLost)])
        case "stop": .handsFree(at: lead, talk: clip + 30)
        default: throw CLIError("unknown script \(script)")
        }
        switch script {
        case "hold": endsAt = sendKey ? clip + 0.1 : clip + 0.15
        case "handsfree": endsAt = clip + 0.5
        default: break
        }
        let micDelay = args.double("mic-delay", 0.03)
        let folder = URL(fileURLWithPath: args.value("history") ?? NSTemporaryDirectory()).appendingPathComponent(args.value("history") == nil ? "saylark-simulate-\(UUID().uuidString)" : "")
        let suite = "saylark.simulate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(args.flag("warm"), forKey: ShadowEngine.SettingsKey.keepMicReady)
        defaults.set(trigger.rawValue, forKey: DictationSettingsKey.triggerKey)
        if sendKey { defaults.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn) }
        if args.flag("no-paragraphs") { defaults.set(false, forKey: DictationSettingsKey.paragraphsFromPauses) }
        defer {
            defaults.removePersistentDomain(forName: suite)
            if args.value("history") == nil, !args.flag("keep") { try? FileManager.default.removeItem(at: folder) }
        }

        let unplug = args.value("unplug-after").flatMap(Double.init)
        let source = FakeAudioSource(samples: samples, pace: .realtime, startDelay: micDelay, failAfter: unplug, name: "Fake Q2U")
        var parts = ShadowEngine.Parts(
            makeFnSource: { fn }, makeAudioSource: { source }, historyFolder: folder, defaults: defaults,
            frontmostApp: { ("com.example.simulated", "Simulated App") })
        // The engine installs the key hook before it loads the model (so an early press can say
        // "not ready"). The script starts with the hook, so load the model first: the scripted
        // presses then land on a ready engine, as they did before.
        let loadStart = ContinuousClock.now
        let loaded = try await ShadowEngine.loadModels { s in print("model: \(s)") }
        log("model loaded in \(fmt(loadStart.msSince)) ms")
        parts.loadModels = { _ in loaded }
        // Names and jargon: off unless a store is given, so runs are repeatable.
        if let dict = args.value("dict") { parts.dictionaryURL = URL(fileURLWithPath: (dict as NSString).expandingTildeInPath) }
        if let sim {
            parts.makeInserter = { sim.inserter() }
            parts.makeReturnInterceptor = { sim.tap }
        }
        let engine = try ShadowEngine(parts: parts)

        let startedEngine = ContinuousClock.now
        let modelTask = Task { @MainActor in
            for await s in engine.modelStates() { log("model: \(s)"); if s == .ready { break } }
        }
        log("clip \(fmt(clip, 2)) s, script \(script)\(sendKey ? " send" : ""), trigger \(trigger.rawValue), mic start delay \(fmt(micDelay * 1000)) ms, history \(folder.path)")
        try await engine.start()
        modelTask.cancel()
        log("engine ready in \(fmt(startedEngine.msSince)) ms (hook \(fn.kind))")

        // Times relative to the first Fn press.
        let t0 = fn.startedAt + lead
        sim?.t0 = t0
        func at() -> String { String(format: "%8.1f ms", (HotkeyClock.now - t0) * 1000) }
        var levels = 0, wordUpdates = 0, firstLevel: String?, firstWords: String?, lastWords: [String] = []
        var saved: DictationRecord?
        let expectSave = ["hold", "handsfree", "esc", "lostup", "stop"].contains(script)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(clip + 30))
            log("timed out")
            exit(1)
        }
        if script == "stop" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(lead + clip / 2))
                print("\(String(format: "%8.1f ms", (HotkeyClock.now - (fn.startedAt + lead)) * 1000))  engine.stop() (pause)")
                engine.stop()
            }
        }
        loop: for await event in engine.events {
            switch event {
            case .level:
                levels += 1
                if firstLevel == nil { firstLevel = at(); print("\(at())  first level") }
            case .pill(.words(let w), _):
                wordUpdates += 1
                lastWords = w
                if firstWords == nil { firstWords = at(); print("\(at())  first words: \(w.prefix(8).joined(separator: " "))") }
            case .pill(let e, _):
                print("\(at())  pill \(e)")
                if !expectSave, case .finish = e { break loop }
            case .saved(let r):
                print("\(at())  saved \(r.outcome.rawValue) release→text \(r.releaseToTextMs.map { fmt($0) } ?? "-") ms")
                saved = r
                break loop
            }
        }
        if let sim, let r = saved {
            // The clipboard goes back after the paste: wait for the insertion to settle.
            if script == "esc", r.outcome == .cancelled {
                print("\(at())  paste(cancelled take) from the menu")
                let o = await engine.paste(r.id)
                print("\(at())  paste → \(o.rawValue)")
                if o == .inserted, !(await sim.waitFor("clipboard restored")) { print("\(at())  clipboard not restored within 3 s") }
                try? await Task.sleep(for: .milliseconds(100))  // the outcome update lands
            }
            if case .card = r.outcome {
                print("\(at())  card showing; Dismiss")
                engine.cardDismiss()
            }
            await engine.waitForTakes()
            if let fresh = try await engine.store.record(r.id) { saved = fresh }
            sim.summary(released: endsAt.map { t0 + $0 })
            if let m = try await engine.store.metrics(for: r.id)?.insertion {
                print("metrics: outcome \(m.outcome), text \(m.textMs.map { fmt($0) } ?? "-") ms, release→⌘V \(m.releaseToPasteMs.map { fmt($0, 1) } ?? "-") ms, "
                      + "first read \(m.firstReadMs.map { fmt($0, 1) } ?? "-") ms, restore \(m.restoreMs.map { fmt($0, 1) } ?? "-") ms, clipboard \(m.clipboard ?? "-"), "
                      + "read wait \(m.readWaitMs.map { fmt($0, 1) } ?? "-") ms, release→Return \(m.releaseToReturnMs.map { fmt($0, 1) } ?? "-") ms\(m.sendSkipped.map { ", send skipped: \($0)" } ?? "")")
            }
            print("sent: \(saved?.sent ?? false)")
        }
        watchdog.cancel()
        engine.stop()

        print("\n--- summary ---")
        print("levels: \(levels) (\(fmt(Double(levels) / max(0.001, clip), 1)) per audio second), first at \(firstLevel ?? "-")")
        print("live word updates: \(wordUpdates), first at \(firstWords ?? "-"), last had \(lastWords.count) words")
        if let m = engine.lastMetrics {
            print("mic start \(m.micStartMs.map { fmt($0) } ?? "warm") ms, pre-roll \(fmt(m.preRollSeconds, 2)) s, windows \(m.windows), partials \(m.partials), reused partial at release: \(m.reusedPartial)")
            print("main thread at Fn-down \(m.beginMs.map { fmt($0, 2) } ?? "-") ms, mic open (off main) \(m.micOpenMs.map { fmt($0, 1) } ?? "warm") ms, failed windows \(m.failedWindows)")
        }
        if let r = saved {
            print("record: \(r.outcome.rawValue), \(fmt(r.duration, 2)) s, hands-free \(r.handsFree), app \(r.appName ?? "-"), release→text \(r.releaseToTextMs.map { fmt($0) } ?? "-") ms")
            print("text: \(r.cleanText)")
            if let url = engine.store.audioURL(for: r), let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int {
                print("audio: \(url.lastPathComponent) \(size / 1024) KB")
            }
            let found = try await engine.store.search(String(r.cleanText.split(separator: " ").first ?? ""), limit: 5)
            print("history: \(try await engine.store.count()) take(s); search finds it: \(found.contains { $0.id == r.id })")
        } else {
            print("nothing saved (expected for \(script))")
        }
    }
}
