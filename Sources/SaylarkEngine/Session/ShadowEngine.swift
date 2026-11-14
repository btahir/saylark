import AppKit
import Foundation
import SaylarkCore

/// The engine: hears the trigger key (listen-only), captures the take, transcribes it while you
/// talk, pastes the text at the cursor the moment it is final (`ShadowEngine+Active.swift`) and
/// logs it to history. (The name is historical: the Shadow mode that only listened is gone.)
///
/// Everything outside is injected (`Parts`): the app passes the real hook, mic, folders and the
/// real `Inserter`; `saylark simulate` and tests pass a scripted key timeline, a fake mic, a temp
/// folder and an `Inserter` over an in-memory clipboard.
///
/// Never loses a take: every take's audio is spooled to disk while it is spoken (`TakeSpool`), a
/// failed transcription still saves the take with its audio as `.failed`, spools left by a crash
/// are transcribed and saved at the next start, cancelled takes are transcribed in the background
/// and kept, and `stop()` finishes a running take.
@MainActor
public final class ShadowEngine: DictationEngine {
    public enum EngineError: Error, CustomStringConvertible {
        /// No longer thrown: Active mode is available. Kept for source compatibility.
        case activeNotAvailable
        case notStarted
        case noAudio

        public var description: String {
            switch self {
            case .activeNotAvailable: "Active mode (pasting) is not available."
            case .notStarted: "The engine is not started."
            case .noAudio: "This take has no saved audio."
            }
        }
    }

    /// Dictate and send timings.
    public struct SendConfig: Sendable, Equatable {
        /// Return is pressed only after the target read the pasted text, waiting at most this long
        /// after ⌘V. No read by then: no Return (the paste did not land).
        public var readCap: Double = 1.5
        /// After the read, wait this long before Return, so a Chromium probe read followed by the
        /// real paste has finished before Return arrives.
        public var delayAfterRead: Double = 0.05

        public init() {}
    }

    /// What the engine is built from.
    public struct Parts {
        public var makeFnSource: @MainActor () throws -> any FnEventSource
        /// Called each time the mic opens (off the main thread), so the device is chosen at that moment.
        public var makeAudioSource: @Sendable () throws -> any AudioSource
        public var historyFolder: URL
        public var frontmostApp: @MainActor () -> (bundleID: String?, name: String?)
        /// Settings (`microphoneUID`, `keepMicReady`, `keepAudioDays`, `liveWords`, and the
        /// `DictationSettingsKey`s: trigger key, send on Return, paragraphs).
        public var defaults: UserDefaults
        public var gesture = FnGesture.Config.wisprFlow
        /// The pill waits this long after Fn-down, so a Fn chord (Fn+arrow, Fn+F5) never flashes it.
        /// Capture still starts at Fn-down.
        public var pillDelay: Double = 0.08
        public var transcriber = StreamingTranscriber.Config.live
        /// While Fn is believed down, the real Fn state is checked this often (seconds) to catch a
        /// release the hook missed. 0 turns the check off.
        public var fnCheckInterval: Double = 0.75
        /// A push-to-talk hold longer than this (seconds) is a stuck key, not a dictation: the take
        /// is finished (and saved) as if Fn went up.
        public var holdCeiling: Double = 600
        /// Watch audio devices (re-pick a warm mic on hot-plug) and wake from sleep (re-warm the
        /// model, re-pick the mic, re-check Fn). The real app turns this on.
        public var watchSystem = false
        /// Loads the speech model; replaced by tests and the CLI to reuse a loaded one (or fake it).
        public var loadModels: @Sendable (@escaping @Sendable (ModelState) -> Void) async throws -> (any SpeechTranscribing, any VoiceDetecting)
        /// The user's dictionary (`DictionaryFile`): names and jargon, and what they get misheard
        /// as. Nil turns correction off (tests, `saylark simulate` unless asked). The real app uses
        /// `DictionaryFile.defaultURL`. The file is watched and reloaded when it changes.
        public var dictionaryURL: URL?
        /// The old vocabulary store. When the dictionary file does not exist yet, its live terms are
        /// written into it once. It is also read for the ordinary words learned from the user's
        /// writing (the corrector's guards). Opened read-only, never changed.
        public var legacyVocabularyURL: URL?
        /// The insertion path (every take, and `paste(_:)`). The default is inert (an in-memory
        /// clipboard and keys that go nowhere); only `.app` builds the real one.
        public var makeInserter: @MainActor () -> Inserter = { ShadowEngine.inertInserter() }
        /// Swallows Return during a take for dictate and send. Nil turns sending off.
        public var makeReturnInterceptor: @MainActor () -> (any ReturnInterceptor)? = { nil }
        /// Bundle IDs of running apps, for the trigger clash check.
        public var runningApps: @MainActor () -> [String] = { [] }
        public var send = SendConfig()
        public var paragraphs = Paragraphs.Config()
        /// Safety net: a card the app never closes is closed by the engine after this long
        /// (seconds), so its insertion settles and the clipboard is never left waiting. The pill
        /// closes it itself after 8 s without hover.
        public var cardTimeout: Double = 120

        public init(
            makeFnSource: @escaping @MainActor () throws -> any FnEventSource,
            makeAudioSource: @escaping @Sendable () throws -> any AudioSource,
            historyFolder: URL, defaults: UserDefaults,
            frontmostApp: @escaping @MainActor () -> (bundleID: String?, name: String?) = ShadowEngine.frontmostApp,
            loadModels: @escaping @Sendable (@escaping @Sendable (ModelState) -> Void) async throws -> (any SpeechTranscribing, any VoiceDetecting) = ShadowEngine.loadModels
        ) {
            self.makeFnSource = makeFnSource
            self.makeAudioSource = makeAudioSource
            self.historyFolder = historyFolder
            self.defaults = defaults
            self.frontmostApp = frontmostApp
            self.loadModels = loadModels
        }

        /// The real app: Fn hook by permission, the policy-chosen mic, Application Support, the real
        /// clipboard and keys, the Return tap.
        public static func app(defaults: UserDefaults = .standard) -> Parts {
            // UserDefaults is thread-safe.
            nonisolated(unsafe) let settings = defaults
            var parts = Parts(
                makeFnSource: { try FnHook.makeSource() },
                makeAudioSource: {
                    let pinned = settings.string(forKey: SettingsKey.microphoneUID)
                    guard let device = AudioDevices.choose(pinnedUID: pinned) else { throw AudioSourceFailure.deviceLost(name: "microphone") }
                    return HALAudioSource(device: device)
                },
                historyFolder: HistoryStore.defaultFolder,
                defaults: defaults)
            parts.watchSystem = true
            parts.makeInserter = { Inserter(parts: .system()) }
            parts.makeReturnInterceptor = { ReturnKeyTap() }
            parts.runningApps = { NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) }
            parts.dictionaryURL = DictionaryFile.defaultURL
            parts.legacyVocabularyURL = VocabularyStore.defaultURL
            return parts
        }
    }

    /// UserDefaults keys shared with the app's settings (`AppSettings.Key`).
    public enum SettingsKey {
        public static let microphoneUID = "microphoneUID"
        public static let keepMicReady = "keepMicReady"
        /// 0 = forever.
        public static let keepAudioDays = "keepAudioDays"
        public static let liveWords = "liveWords"
    }

    /// One running take.
    struct Take {
        let id: UUID
        let startedAt: Date
        let startClock: Double
        var handsFree = false
        let appBundleID: String?
        let appName: String?
        let transcriber: StreamingTranscriber
        /// Nil if the spool file could not be created (the take still runs, with no crash safety).
        let spool: TakeSpool?
        /// Main-thread time `begin()` took, ms.
        var beginMs: Double?
        /// Focus captured at take start (off the main thread).
        let focus: Task<FocusInfo, Never>?
        /// Return during this take means "stop, paste and send" (`SendOnReturn` covers the app that
        /// had focus at take start).
        let sendApplies: Bool
        /// The Return interceptor is armed.
        var returnArmed = false
    }

    /// The trigger key in use. Read from `DictationSettingsKey.triggerKey`; a change is applied
    /// between takes.
    public private(set) var triggerKey: TriggerKey = .fn
    public let events: AsyncStream<DictationEvent>
    /// Why takes ended where they did, finer than the pill events (`EngineNotice`).
    public let notices: AsyncStream<EngineNotice>
    public var history: any HistoryReading { store }
    public let store: HistoryStore
    /// The insertion path, built from `Parts.makeInserter`.
    public let inserter: Inserter

    let parts: Parts
    let continuation: AsyncStream<DictationEvent>.Continuation
    let noticeSink: AsyncStream<EngineNotice>.Continuation
    private var gesture: FnGesture
    private var gestureConfig: FnGesture.Config
    private(set) var fnSource: (any FnEventSource)?
    var returnTap: (any ReturnInterceptor)?
    private var deadlineTimer: DispatchWorkItem?
    private var fnCheckTimer: DispatchWorkItem?
    /// The source's `isFnDown()` has reported Fn down during a press at least once, so its "up"
    /// can be trusted to end a stuck take.
    private var fnStateTrusted = false
    private let capture: Capture
    private var corrector: VocabularyCorrector?
    private var dictionaryWatcher: FileWatcher?
    private var dictionaryLoads = 0
    /// What the last dictionary load found: usable entries and skipped lines.
    public private(set) var dictionaryStatus: (entries: Int, problems: [DictionaryFile.Problem]) = (0, [])
    private(set) var recognizer: (any SpeechTranscribing)?
    private(set) var voice: (any VoiceDetecting)?
    private var take: Take?
    private var pillShowItem: DispatchWorkItem?
    private var pillShown = false
    private var modelState: ModelState = .notLoaded
    private var modelWatchers: [UUID: AsyncStream<ModelState>.Continuation] = [:]
    private var defaultsObserver: (any NSObjectProtocol)?
    private var keepWarmApplied: Bool?
    private var triggerApplied: String?
    private var pendingTrigger: TriggerKey?
    private var wakeObserver: (any NSObjectProtocol)?
    private var deviceWatcher: AudioDeviceWatcher?
    private var lastPrune = Date.distantPast
    /// Takes whose save is still running (finish or recovery), so recovery never races them.
    var saving: Set<UUID> = []
    /// The finish or cancel work of takes not yet saved.
    var inflight: [UUID: Task<Void, Never>] = [:]
    /// Active takes saved but whose insertion has not settled (clipboard not back yet, or the card
    /// still showing). Kept apart from `inflight`: a card can stay up as long as the user wants.
    var settling: [UUID: Task<Void, Never>] = [:]
    /// Insertions that pasted, by take: a later "not read" turns into `.pasteFailed`.
    var pastedTakes: [UUID: UUID] = [:]
    /// Outcome changes (card buttons) that arrived while the take was still being saved.
    var pendingOutcome: [UUID: DictationOutcome] = [:]
    /// The take whose card is showing, and its insertion.
    var card: CardState?
    private var recovery: Task<Void, Never>?
    private var inserterListener: Task<Void, Never>?
    /// Every finished take's timings, newest last (for `saylark simulate` and diagnostics).
    public internal(set) var lastMetrics: TakeMetrics?

    struct CardState {
        let take: UUID
        let insertion: UUID
        var waiting = false
    }

    public init(parts: Parts) throws {
        self.parts = parts
        store = try HistoryStore(folder: parts.historyFolder)
        var config = parts.gesture
        config.armsReturn = true
        gestureConfig = config
        gesture = FnGesture(config: config)
        capture = Capture(makeSource: parts.makeAudioSource)
        (events, continuation) = AsyncStream.makeStream(of: DictationEvent.self, bufferingPolicy: .unbounded)
        (notices, noticeSink) = AsyncStream.makeStream(of: EngineNotice.self, bufferingPolicy: .bufferingNewest(64))
        inserter = parts.makeInserter()
        applySettings()
        listenToInserter()
    }

    var spoolFolder: URL { TakeSpool.folder(in: store.folder) }

    // MARK: - DictationEngine

    /// Installs the hook, loads the model and gets ready. The hook goes in first, so a press while
    /// the model loads can say so (`EngineNotice.modelNotReady`) instead of doing nothing.
    public func start() async throws {
        applySettings()
        observeDefaults()
        var hookError: (any Error)?
        if fnSource == nil {
            do {
                let source = try parts.makeFnSource()
                source.setTrigger(triggerKey)
                try source.start { input in
                    // FIFO onto the main thread, so key order is kept.
                    DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.handle(input) } }
                }
                fnSource = source
            } catch {
                hookError = error
            }
        }
        if recognizer == nil {
            setModelState(.notLoaded)
            do {
                // Progress arrives on any thread; keep only states that move forward, so a late
                // `.compiling` hop can't land after `.ready`.
                let (r, v) = try await parts.loadModels { state in
                    Task { @MainActor [weak self] in
                        guard let self, self.modelState != .ready else { return }
                        self.setModelState(state)
                    }
                }
                recognizer = r
                voice = v
                setModelState(.ready)
            } catch {
                setModelState(.failed(String(describing: error)))
                throw error
            }
        }
        if dictionaryWatcher == nil, let url = parts.dictionaryURL { await watchDictionary(url) }
        try? await pruneIfDue()
        applyKeepWarm()
        if parts.watchSystem { watchSystem() }
        recoverSpools()
        if let hookError { throw hookError }
    }

    /// Stops listening. A take that is running is finished and saved, not thrown away (but not
    /// pasted: pausing should not type into whatever has focus).
    public func stop() {
        fnSource?.stop()
        fnSource = nil
        if take != nil { finish(releasedAt: HotkeyClock.now, send: false, deliver: false) }
        returnTap?.disarm()
        gesture = FnGesture(config: gestureConfig)
        deadlineTimer?.cancel()
        deadlineTimer = nil
        fnCheckTimer?.cancel()
        fnCheckTimer = nil
        pillShowItem?.cancel()
        pillShowItem = nil
        capture.setKeepWarm(false)
        keepWarmApplied = nil
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        defaultsObserver = nil
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        wakeObserver = nil
        deviceWatcher = nil
        dictionaryWatcher?.stop()
        dictionaryWatcher = nil
        if card != nil { cardDismiss() }
        let inserter = self.inserter
        Task { await inserter.flush() }
    }

    public func finishTake() {
        gesture.reset()
        finish(releasedAt: HotkeyClock.now, send: false)
    }

    public func cancelTake() {
        gesture.reset()
        cancel(save: true)
    }

    public func modelStates() -> AsyncStream<ModelState> {
        let (stream, c) = AsyncStream.makeStream(of: ModelState.self, bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        c.yield(modelState)
        modelWatchers[id] = c
        c.onTermination = { _ in Task { @MainActor [weak self] in self?.modelWatchers[id] = nil } }
        return stream
    }

    /// Waits until spool recovery from `start()` is done. For tests and the CLI.
    public func waitForRecovery() async {
        await recovery?.value
    }

    /// Waits until every finished or cancelled take is saved and its insertion settled.
    /// A take whose card is still showing settles when the card closes (at the latest after
    /// `Parts.cardTimeout`).
    public func waitForTakes() async {
        while let (id, task) = inflight.first {
            await task.value
            inflight[id] = nil
        }
        while let (id, task) = settling.first {
            await task.value
            settling[id] = nil
        }
    }

    // MARK: - Gestures

    /// Applies one key fact from the hook. Public for tests that drive the engine directly.
    public func handle(_ input: FnGesture.Input) {
        if case .fnState(let down, _) = input {
            // A reported "up" ends a take only once the system has been seen reporting Fn down:
            // if this Mac never reports Fn in its HID flags, a resync must not cut real holds.
            if down { if gesture.fnDown { fnStateTrusted = true } } else if !fnStateTrusted { return }
        }
        for action in gesture.handle(input) { perform(action, at: input.time) }
        scheduleDeadline()
        scheduleFnCheck()
        applyPendingTrigger()
    }

    private func scheduleDeadline() {
        deadlineTimer?.cancel()
        deadlineTimer = nil
        guard let deadline = gesture.deadline else { return }
        let item = DispatchWorkItem { MainActor.assumeIsolated { [weak self] in self?.handle(.tick(time: deadline)) } }
        deadlineTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - HotkeyClock.now), execute: item)
    }

    /// While Fn is believed down, check the real key on a slow timer. A release the hook missed
    /// (tap disabled by timeout, rebuilt on wake, asleep with Fn held) would otherwise leave the
    /// take recording until the next release, and ignore the next press.
    private func scheduleFnCheck() {
        guard gesture.fnDown, parts.fnCheckInterval > 0 else {
            fnCheckTimer?.cancel()
            fnCheckTimer = nil
            return
        }
        guard fnCheckTimer == nil else { return }
        let item = DispatchWorkItem { MainActor.assumeIsolated { [weak self] in self?.checkFn() } }
        fnCheckTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + parts.fnCheckInterval, execute: item)
    }

    private func checkFn() {
        fnCheckTimer = nil
        guard gesture.fnDown else { return }
        let now = HotkeyClock.now
        if let down = fnSource?.isFnDown() {
            if down {
                fnStateTrusted = true
            } else if fnStateTrusted {
                // Only trusted once the system has been seen reporting Fn down during a press:
                // if it never reports Fn at all, this check must not end real holds.
                handle(.fnState(down: false, time: now))
                return
            }
        }
        if case .pressed(let at) = gesture.phase, now - at >= parts.holdCeiling {
            handle(.fnState(down: false, time: now))
            return
        }
        scheduleFnCheck()
    }

    private func perform(_ action: FnGesture.Action, at time: Double) {
        switch action {
        case .listen:
            let t0 = HotkeyClock.now
            begin()
            take?.beginMs = (HotkeyClock.now - t0) * 1000
        case .lockHandsFree:
            // No take (pressed before the model was ready): the not-ready notice stays as it is.
            guard take != nil else { return }
            showPill()
            take?.handsFree = true
            take?.spool?.update(handsFree: true)
            continuation.yield(.pill(.lockHandsFree, take: take?.id))
        case .armReturn: armReturn()
        case .disarmReturn: returnTap?.disarm()
        case .finish: showPill(); finish(releasedAt: time, send: false)
        case .finishAndSend: showPill(); finish(releasedAt: time, send: true)
        case .cancel: showPill(); cancel(save: true)
        case .discard: discard()
        }
    }

    /// The take is a dictation now: swallow Return if it should stop, paste and send.
    private func armReturn() {
        guard let t = take, t.sendApplies else { return }
        if returnTap == nil { returnTap = parts.makeReturnInterceptor() }
        guard let tap = returnTap else { return }
        let armed = tap.arm(trigger: triggerKey) { [weak self] time in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(.returnKey(time: time)) } }
        }
        take?.returnArmed = armed
    }

    // MARK: - Takes

    private func begin() {
        guard take == nil else { return }
        guard let recognizer, let voice else {
            // The trigger works before the model does: say why nothing happens.
            continuation.yield(.pill(.fail(.modelNotReady(message: modelState.notReadyMessage))))
            noticeSink.yield(.modelNotReady(modelState))
            return
        }
        let app = parts.frontmostApp()
        let id = UUID()
        let send = continuation
        // Focus first: the probe runs off the main thread while the rest of the take starts.
        let inserter = self.inserter
        let focus = Task { await inserter.captureFocus() }
        let liveWords = parts.defaults.object(forKey: SettingsKey.liveWords) as? Bool ?? false
        var onWords: (@Sendable ([String]) -> Void)?
        if liveWords { onWords = { @Sendable (words: [String]) -> Void in _ = send.yield(.pill(.words(words), take: id)) } }
        // Live words off: partials only at pauses (for the release reuse). Measured on short and
        // mid clips: 16 ms CPU per audio second instead of 60 (notes/M1-engine.md).
        var config = parts.transcriber
        if !liveWords, config.partialInterval > 0 { config.partialInterval = 1_000_000 }
        let transcriber = StreamingTranscriber(recognizer: recognizer, voice: voice, config: config, onWords: onWords)
        let startedAt = Date()
        let spool = try? TakeSpool(
            folder: spoolFolder,
            meta: .init(id: id, startedAt: startedAt, mode: .active, appBundleID: app.bundleID, appName: app.name))
        let t = Take(id: id, startedAt: startedAt, startClock: HotkeyClock.now, appBundleID: app.bundleID, appName: app.name,
                     transcriber: transcriber, spool: spool, focus: focus,
                     sendApplies: sendOnReturnApplies(to: app.bundleID))
        take = t
        pillShown = false
        if parts.pillDelay > 0 {
            let show = DispatchWorkItem { MainActor.assumeIsolated { [weak self] in self?.showPill() } }
            pillShowItem = show
            DispatchQueue.main.asyncAfter(deadline: .now() + parts.pillDelay, execute: show)
        } else {
            showPill()
        }
        let sink = Capture.Sink(
            audio: { chunk in
                transcriber.enqueue(chunk)
                spool?.append(chunk)
            },
            levels: { levels in for l in levels { send.yield(.level(l)) } },
            failed: { failure in DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.micFailed(failure, take: id) } } })
        // Opens the mic off the main thread when it is cold; a failure comes back through `failed`.
        capture.beginTake(sink)
    }

    /// Ends the take. `send`: Return ended it (dictate and send). `deliver: false` saves the take
    /// without pasting (`stop()`).
    private func finish(releasedAt released: Double, send: Bool, deliver: Bool = true) {
        guard let t = take else { return }
        take = nil
        returnTap?.disarm()
        let audio = capture.endTake()
        let events = continuation, store = self.store, hook = fnSource?.kind
        let paragraphs = paragraphsConfig()
        let corrector = self.corrector
        saving.insert(t.id)
        inflight[t.id] = Task { [weak self] in
            let out = await t.transcriber.finish()
            // `raw` stays what the recogniser heard (the Library's "what it heard", and what the
            // vocabulary learns from); names are fixed on the way to the clean text.
            let fixed = await Self.corrected(out.transcript, by: corrector)
            let textMs = (HotkeyClock.now - released) * 1000
            let raw = out.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let failed = out.failedWindows > 0
            let clean = Self.clean(fixed.text, words: fixed.words, duration: audio.duration, paragraphs: paragraphs)
            var metrics = TakeMetrics(
                micStartMs: audio.micStartMs, preRollSeconds: audio.preRollSeconds, device: audio.deviceName,
                windows: out.windows.count, partials: out.live.partials, reusedPartial: out.live.reusedAtRelease, hook: hook)
            metrics.micOpenMs = audio.micOpenMs
            metrics.beginMs = t.beginMs
            metrics.failedWindows = out.failedWindows
            metrics.voiceDetectionFailed = out.voiceDetectionFailed
            var outcome: DictationOutcome = failed ? .failed : raw.isEmpty ? .empty : .logged
            var releaseMs = textMs
            var sent = false
            var settled: Task<InsertionMachine.Settlement, Never>?
            if deliver, let self {
                // Insert before the m4a encode and the save: the user is waiting for the text.
                let d = await self.deliver(t, clean: clean, failed: failed, released: released, send: send, textMs: textMs)
                outcome = d.outcome
                releaseMs = d.releaseMs
                sent = d.sent
                metrics.insertion = d.metrics
                settled = d.settled
            } else if failed {
                events.yield(.pill(.fail(.transcriptionFailed), take: t.id))
            } else {
                events.yield(.pill(.finish(raw.isEmpty ? .empty : .inserted), take: t.id))
            }
            var record = DictationRecord(
                id: t.id, startedAt: t.startedAt, duration: audio.duration, mode: .active, handsFree: t.handsFree,
                appBundleID: t.appBundleID, appName: t.appName, rawText: raw, cleanText: clean,
                words: fixed.words, releaseToTextMs: releaseMs, outcome: outcome)
            record.sent = sent
            if let o = self?.pendingOutcome.removeValue(forKey: t.id) { record.outcome = o }
            await Self.persist(&record, metrics: metrics, spool: t.spool, store: store)
            events.yield(.saved(record))
            await self?.afterSave(record, metrics: metrics)
            if let settled, let self {
                self.settling[t.id] = Task { [weak self] in
                    let s = await settled.value
                    await self?.recordSettlement(t.id, s)
                    self?.settling[t.id] = nil
                }
            }
            self?.inflight[t.id] = nil
        }
    }

    func afterSave(_ record: DictationRecord, metrics: TakeMetrics?) async {
        saving.remove(record.id)
        if let metrics { lastMetrics = metrics }
        // A card button pressed while the take was being saved.
        if let o = pendingOutcome.removeValue(forKey: record.id), o != record.outcome { setOutcome(record.id, o) }
        try? await pruneIfDue()
    }

    /// Esc or the pill: the take ends at once, but it is still transcribed in the background and
    /// saved with its text (outcome `.cancelled`, audio kept for a day), so `paste(_:)` can bring
    /// it back instantly.
    private func cancel(save: Bool) {
        guard let t = take else { return }
        take = nil
        returnTap?.disarm()
        let audio = capture.endTake()
        continuation.yield(.pill(.cancel, take: t.id))
        guard save, audio.sampleCount > 0 else {
            t.transcriber.cancelNow()
            Task { await t.spool?.close(); t.spool?.remove() }
            return
        }
        let events = continuation, store = self.store
        let paragraphs = paragraphsConfig()
        let corrector = self.corrector
        saving.insert(t.id)
        inflight[t.id] = Task { [weak self] in
            let out = await t.transcriber.finish()
            let fixed = await Self.corrected(out.transcript, by: corrector)
            let raw = out.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var metrics = TakeMetrics(windows: out.windows.count, partials: out.live.partials)
            metrics.failedWindows = out.failedWindows
            var record = DictationRecord(
                id: t.id, startedAt: t.startedAt, duration: audio.duration,
                mode: .active, handsFree: t.handsFree, appBundleID: t.appBundleID, appName: t.appName,
                rawText: raw, cleanText: Self.clean(fixed.text, words: fixed.words, duration: audio.duration, paragraphs: paragraphs),
                words: fixed.words, outcome: .cancelled)
            await Self.persist(&record, metrics: metrics, spool: t.spool, store: store)
            events.yield(.saved(record))
            await self?.afterSave(record, metrics: nil)
            self?.inflight[t.id] = nil
        }
    }

    /// A short tap or a Fn chord: not a dictation. Nothing is kept.
    private func discard() {
        guard let t = take else { return }
        take = nil
        returnTap?.disarm()
        _ = capture.endTake()
        t.transcriber.cancelNow()
        Task { await t.spool?.close(); t.spool?.remove() }
        pillShowItem?.cancel()
        pillShowItem = nil
        if pillShown { continuation.yield(.pill(.finish(.empty), take: t.id)) }
    }

    /// Shows the pill for the current take, once. Called by the delay timer, or early when the take
    /// changes state before the delay is up.
    private func showPill() {
        pillShowItem?.cancel()
        pillShowItem = nil
        guard let t = take, !pillShown else { return }
        pillShown = true
        continuation.yield(.pill(.listen, take: t.id))
    }

    private func micFailed(_ failure: AudioSourceFailure, take id: UUID) {
        let error: PillError
        switch failure {
        case .deviceLost(let n): error = .microphoneMissing(name: n)
        case .startFailed:
            error = EnginePermissions.status().microphone == .granted ? .microphoneMissing(name: "microphone") : .microphoneAccessOff
        }
        // A failure from an earlier take (or a warm mic between takes) must not end this one.
        guard let t = take, t.id == id else {
            continuation.yield(.pill(.fail(error)))
            return
        }
        gesture.reset()
        scheduleDeadline()
        scheduleFnCheck()
        showPill()
        if capture.endTakeIfSilent() {
            // The mic never delivered anything (it would not open): nothing to keep.
            take = nil
            returnTap?.disarm()
            t.transcriber.cancelNow()
            Task { await t.spool?.close(); t.spool?.remove() }
        } else {
            // Keep what was said before the unplug.
            finish(releasedAt: HotkeyClock.now, send: false)
        }
        continuation.yield(.pill(.fail(error), take: t.id))
    }

    /// Encodes the m4a from the spool, saves the record, then removes the spool. The spool is removed
    /// only once the record is in the database, so a crash anywhere before that recovers the take.
    nonisolated static func persist(_ record: inout DictationRecord, metrics: TakeMetrics?, spool: TakeSpool?, store: HistoryStore) async {
        if let spool {
            await spool.close()
            if spool.sampleCount > 0 {
                record.audioPath = await saveAudio(spool: spool.audioURL, id: record.id, startedAt: record.startedAt, folder: store.folder)
            }
        }
        do {
            try await store.save(record, metrics: metrics)
            // Keep the spool if the m4a could not be written: the next start recovers the audio.
            if let spool, record.audioPath != nil || spool.sampleCount == 0 { spool.remove() }
        } catch {
            NSLog("Saylark: could not save take \(record.id): \(error). Its spool is kept for recovery.")
        }
    }

    /// The text a take gets: paragraph breaks from long pauses (when on), then literal cleanup.
    nonisolated static func clean(_ raw: String, words: [TranscriptWord], duration: Double, paragraphs: Paragraphs.Config?) -> String {
        let text = paragraphs.map { Paragraphs.apply(raw, words: words, duration: duration, config: $0) } ?? raw
        return Cleanup.apply(text)
    }

    // MARK: - Vocabulary

    /// Swaps known mishearings for the term ("UTLDR" → "YouTLDR"). Swap mode needs no audio and
    /// costs well under a millisecond on a normal take.
    nonisolated static func corrected(_ transcript: Transcript, by corrector: VocabularyCorrector?) async -> Transcript {
        guard let corrector, !transcript.text.isEmpty else { return transcript }
        return await corrector.correct(transcript, samples: []).transcript
    }

    /// Moves the old vocabulary into the dictionary on first run, loads it, and reloads it whenever
    /// the file changes (an edit in any editor, `saylark dict`, the Dictionary tab).
    private func watchDictionary(_ url: URL) async {
        let legacy = parts.legacyVocabularyURL
        await Task.detached(priority: .utility) {
            do {
                if let moved = try DictionaryMigration.migrateIfNeeded(dictionary: url, legacy: legacy) {
                    NSLog("Saylark: dictionary created from the old vocabulary: \(moved.terms) terms, \(moved.aliases) heard-as forms")
                }
            } catch {
                NSLog("Saylark: dictionary not created from the old vocabulary: \(error)")
            }
        }.value
        await loadDictionary(url)
        let watcher = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in await self?.loadDictionary(url) }
        }
        watcher.start()
        dictionaryWatcher = watcher
    }

    /// Ordinary words: the system list plus those learned from the user's writing by the old store.
    nonisolated private static let commonWordsCache = Locked<[String: CommonWords]>([:])

    nonisolated static func commonWords(legacy: URL?) -> CommonWords {
        let key = legacy?.path ?? ""
        if let c = commonWordsCache.withLock({ $0[key] }) { return c }
        let c = CommonWords(CommonWords.system().words.union(DictionaryMigration.ordinaryWords(legacy: legacy)))
        commonWordsCache.withLock { $0[key] = c }
        return c
    }

    /// Reads the dictionary off the main thread and swaps in a new corrector. A missing or empty
    /// file means no correction; a malformed line is skipped. The newest load wins.
    func loadDictionary(_ url: URL) async {
        dictionaryLoads += 1
        let load = dictionaryLoads
        let legacy = parts.legacyVocabularyURL
        let loaded = await Task.detached(priority: .utility) { () -> (VocabularyCorrector?, Int, [DictionaryFile.Problem]) in
            let file = (try? DictionaryFile.load(url)) ?? DictionaryFile.parse("")
            let common = Self.commonWords(legacy: legacy)
            let terms = file.terms(common: common)
            guard !terms.isEmpty else { return (nil, 0, file.problems) }
            var config = VocabularyCorrector.Config()
            config.termLimit = max(config.termLimit, terms.count)  // every entry the user wrote
            let corrector = try? await VocabularyCorrector.load(terms: terms, common: common, config: config)
            return (corrector, terms.count, file.problems)
        }.value
        guard load == dictionaryLoads else { return }
        corrector = loaded.0
        dictionaryStatus = (loaded.1, loaded.2)
    }

    func paragraphsConfig() -> Paragraphs.Config? {
        let on = parts.defaults.object(forKey: DictationSettingsKey.paragraphsFromPauses) as? Bool ?? true
        return on ? parts.paragraphs : nil
    }

    // MARK: - Crash recovery and re-transcription

    /// Transcribes and saves takes whose spool outlived the run that recorded them (a crash or
    /// force-quit during the take). Runs in the background after start, at utility priority.
    private func recoverSpools() {
        guard recovery == nil, let recognizer, let voice else { return }
        let folder = spoolFolder, store = self.store, send = continuation
        var busy = saving
        if let id = take?.id { busy.insert(id) }
        let orphans = TakeSpool.orphans(in: folder, excluding: busy)
        guard !orphans.isEmpty else { return }
        var config = parts.transcriber
        config.partialInterval = 0
        config.priority = .utility
        let paragraphs = paragraphsConfig()
        let corrector = self.corrector
        recovery = Task.detached(priority: .utility) {
            for orphan in orphans {
                if let record = await Self.recover(orphan, recognizer: recognizer, voice: voice, config: config, paragraphs: paragraphs, store: store, corrector: corrector) {
                    send.yield(.saved(record))
                }
            }
        }
    }

    nonisolated private static func recover(_ orphan: TakeSpool.Orphan, recognizer: any SpeechTranscribing, voice: any VoiceDetecting, config: StreamingTranscriber.Config, paragraphs: Paragraphs.Config?, store: HistoryStore, corrector: VocabularyCorrector? = nil) async -> DictationRecord? {
        let count = orphan.sampleCount
        guard count > 0 else {
            TakeSpool.remove(audio: orphan.audio)
            return nil
        }
        let transcriber = StreamingTranscriber(recognizer: recognizer, voice: voice, config: config)
        do {
            let reader = try TakeSpool.Reader(orphan.audio)
            while let chunk = try reader.next(16_000) { try await transcriber.append(chunk) }
        } catch {
            NSLog("Saylark: could not read spool \(orphan.audio.lastPathComponent): \(error)")
        }
        let out = await transcriber.finish()
        let fixed = await corrected(out.transcript, by: corrector)
        let raw = out.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = orphan.meta
        let duration = Double(count) / Double(Recognizer.sampleRate)
        var record = DictationRecord(
            id: m.id, startedAt: m.startedAt, duration: duration, mode: m.mode,
            handsFree: m.handsFree, appBundleID: m.appBundleID, appName: m.appName, rawText: raw,
            cleanText: clean(fixed.text, words: fixed.words, duration: duration, paragraphs: paragraphs),
            words: fixed.words, outcome: out.failedWindows > 0 ? .failed : raw.isEmpty ? .empty : .logged, recovered: true)
        record.audioPath = await saveAudio(spool: orphan.audio, id: m.id, startedAt: m.startedAt, folder: store.folder)
        var metrics = TakeMetrics(windows: out.windows.count)
        metrics.failedWindows = out.failedWindows
        do {
            try await store.save(record, metrics: metrics)
            TakeSpool.remove(audio: orphan.audio)
            return record
        } catch {
            NSLog("Saylark: could not save recovered take \(m.id): \(error)")
            return nil
        }
    }

    /// Transcribes a saved take again from its audio (a `.failed` take, a cancelled one, or one
    /// whose text looks wrong). Keeps the record's id, times and outcome, except that
    /// a failed or empty take becomes `.logged` (or stays failed/empty).
    @discardableResult
    public func retranscribe(_ id: UUID) async throws -> DictationRecord {
        guard let recognizer, let voice else { throw EngineError.notStarted }
        guard let saved = try await store.record(id), let url = store.audioURL(for: saved) else { throw EngineError.noAudio }
        let samples = try AudioFile.load(url)
        var config = parts.transcriber
        config.partialInterval = 0
        let transcriber = StreamingTranscriber(recognizer: recognizer, voice: voice, config: config)
        var i = 0
        while i < samples.count {
            try await transcriber.append(Array(samples[i..<min(samples.count, i + 16_000)]))
            i += 16_000
        }
        let out = await transcriber.finish()
        let fixed = await Self.corrected(out.transcript, by: corrector)
        let raw = out.transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = Self.clean(fixed.text, words: fixed.words, duration: saved.duration, paragraphs: paragraphsConfig())
        let failed = out.failedWindows > 0
        let words = fixed.words
        guard let record = try await store.update(id, { r, _ in
            r.rawText = raw
            r.cleanText = clean
            r.words = words
            switch r.outcome {
            case .cancelled, .inserted, .copied, .card:
                // What happened to the take stays true; only its text is new.
                break
            case .logged, .failed, .empty:
                r.outcome = failed ? .failed : raw.isEmpty ? .empty : .logged
            }
        }) else { throw EngineError.noAudio }
        continuation.yield(.saved(record))
        return record
    }

    // MARK: - Settings, storage, model state, system events

    private func setModelState(_ state: ModelState) {
        modelState = state
        for c in modelWatchers.values { c.yield(state) }
    }

    /// The trigger key from the defaults. Only a change of the stored value is applied.
    private func applySettings() {
        let triggerRaw = parts.defaults.string(forKey: DictationSettingsKey.triggerKey)
        if triggerRaw != triggerApplied {
            triggerApplied = triggerRaw
            let key = triggerRaw.flatMap(TriggerKey.init(rawValue:)) ?? .fn
            if key != triggerKey {
                pendingTrigger = key
                applyPendingTrigger()
            }
        }
    }

    /// A new trigger key takes over only between takes, with no key believed down.
    private func applyPendingTrigger() {
        guard let key = pendingTrigger, take == nil, gesture.phase == .idle, !gesture.fnDown else { return }
        pendingTrigger = nil
        triggerKey = key
        fnSource?.setTrigger(key)
        gesture = FnGesture(config: gestureConfig)
        fnStateTrusted = false
        fnCheckTimer?.cancel()
        fnCheckTimer = nil
        deadlineTimer?.cancel()
        deadlineTimer = nil
    }

    private func applyKeepWarm() {
        let warm = parts.defaults.bool(forKey: SettingsKey.keepMicReady)
        // Only act on a change: every UserDefaults write in the process lands here.
        guard warm != keepWarmApplied else { return }
        keepWarmApplied = warm
        capture.setKeepWarm(warm)
    }

    private func observeDefaults() {
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: parts.defaults, queue: .main) { _ in
            MainActor.assumeIsolated { [weak self] in
                self?.applyKeepWarm()
                self?.applySettings()
            }
        }
    }

    /// Hot-plug: a warm mic is re-picked between takes (a cold mic is picked at every Fn-down
    /// anyway). Wake: re-warm the model (the Neural Engine may have dropped it), re-pick the mic,
    /// and re-check the Fn key.
    private func watchSystem() {
        if deviceWatcher == nil {
            let capture = self.capture
            // `repick` does nothing during a take; the next take after it picks the device fresh.
            deviceWatcher = AudioDeviceWatcher { capture.repick() }
        }
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { [weak self] in self?.didWake() }
            }
        }
    }

    /// Public for tests; the app calls it on wake from sleep.
    public func didWake() {
        if let recognizer {
            Task.detached(priority: .utility) { try? await recognizer.warmUp() }
        }
        capture.repick()
        if gesture.fnDown, let down = fnSource?.isFnDown() { handle(.fnState(down: down, time: HotkeyClock.now)) }
    }

    private func pruneIfDue() async throws {
        guard Date().timeIntervalSince(lastPrune) > 3600 else { return }
        lastPrune = Date()
        let days = parts.defaults.object(forKey: SettingsKey.keepAudioDays) as? Int ?? 30
        try await store.pruneAudio(keepDays: days == 0 ? nil : days)
    }

    nonisolated private static func saveAudio(spool: URL, id: UUID, startedAt: Date, folder: URL) async -> String? {
        let path = AudioArchive.relativePath(id: id, startedAt: startedAt)
        let task = Task.detached(priority: .utility) { () -> String? in
            do {
                try AudioArchive.writeM4A(spool: spool, to: folder.appendingPathComponent(path))
                return path
            } catch { return nil }
        }
        return await task.value
    }

    // MARK: - Defaults for the real app

    public static func frontmostApp() -> (bundleID: String?, name: String?) {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.localizedName)
    }

    public nonisolated static func loadModels(_ progress: @escaping @Sendable (ModelState) -> Void) async throws -> (any SpeechTranscribing, any VoiceDetecting) {
        let r = try await Recognizer.load(progress: progress)
        let v = try await VoiceActivity.load()
        var state = v.makeState()
        _ = try await v.probability(of: [Float](repeating: 0, count: VoiceActivity.chunkSize), state: &state)
        return (r, v)
    }

    private func listenToInserter() {
        let stream = inserter.events
        inserterListener = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.inserterEvent(event)
            }
        }
    }
}

extension StreamingTranscriber {
    /// Cancels from any context without waiting.
    nonisolated func cancelNow() {
        Task { await self.cancel() }
    }
}
