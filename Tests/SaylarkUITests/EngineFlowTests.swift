import AVFoundation
import AppKit
import Foundation
import Testing
@testable import SaylarkUI
import SaylarkCore

/// An engine whose start and model state the test controls. No mic, no hook.
@MainActor final class ScriptedEngine: DictationEngine {
    let events: AsyncStream<DictationEvent>
    var history: any HistoryReading { store }
    let store = FakeHistory()
    var startCalls = 0
    var stopCalls = 0
    var startError: (any Error)?
    private var model: ModelState = .notLoaded
    private var watchers: [AsyncStream<ModelState>.Continuation] = []

    init() { (events, _) = AsyncStream.makeStream(of: DictationEvent.self) }

    /// While true, `start()` waits for `release()`, like a model that is still loading.
    var holdStart = false
    private var gate: CheckedContinuation<Void, Never>?

    func release() {
        gate?.resume()
        gate = nil
    }

    func start() async throws {
        startCalls += 1
        if holdStart { await withCheckedContinuation { gate = $0 } }
        if let startError { throw startError }
        push(.ready)
    }

    func stop() { stopCalls += 1 }
    func finishTake() {}
    func cancelTake() {}

    func modelStates() -> AsyncStream<ModelState> {
        let (stream, c) = AsyncStream.makeStream(of: ModelState.self)
        c.yield(model)
        watchers.append(c)
        return stream
    }

    func push(_ state: ModelState) {
        model = state
        watchers.forEach { $0.yield(state) }
    }
}

struct ScriptedError: Error, CustomStringConvertible {
    var description: String
}

/// Waits (briefly) for a condition that depends on a stream hopping through the main actor.
@MainActor func until(_ condition: () -> Bool) async {
    for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
}

@MainActor @Suite struct EngineSupervisorTests {
    private func make(_ states: [Permission: PermissionStatus] = [:]) -> (EngineSupervisor, ScriptedEngine, FakePermissions) {
        let engine = ScriptedEngine()
        let perms = FakePermissions(states)
        let s = EngineSupervisor(engine: engine, permissions: perms)
        s.follow()
        return (s, engine, perms)
    }

    @Test func startsAsSoonAsPermissionsExist() async {
        let (s, engine, perms) = make([.microphone: .notDetermined, .inputMonitoring: .granted])
        s.startIfPossible()
        #expect(s.phase == .waitingForPermissions && engine.startCalls == 0)
        #expect(s.fnPressMessage == "Saylark needs permission first. Open its menu.")
        perms.states[.microphone] = .granted
        s.startIfPossible()
        await s.settle()
        #expect(engine.startCalls == 1 && s.phase == .running)
        // Asking again while running does not start twice.
        s.startIfPossible()
        await s.settle()
        #expect(engine.startCalls == 1)
    }

    @Test func modelProgressIsShownThenCleared() async {
        let (s, engine, _) = make()
        engine.holdStart = true
        s.startIfPossible()
        await until { s.model == .notLoaded }
        engine.push(.downloading(progress: 0.424))
        await until { s.model == .downloading(progress: 0.424) }
        #expect(s.statusLine == "Downloading the speech model, 42%")
        #expect(EngineSupervisor.describe(.downloading(progress: 0.424)) == "Downloading the speech model, 42%")
        #expect(s.progress == 0.424)
        engine.push(.compiling(progress: 0.6))
        await until { s.model == .compiling(progress: 0.6) }
        #expect(s.progress == 0.6 && s.fnPressMessage == "Preparing the speech model, 60%.")
        engine.push(.warming)
        await until { s.model == .warming }
        #expect(s.progress == nil && s.fnPressMessage == "Still getting ready. Try again in a moment.")
        engine.release()
        await s.settle()
        await until { s.model == .ready }
        #expect(s.isListening && s.statusLine == nil && s.fnPressMessage == nil)
    }

    @Test func fnBeforeTheModelIsReadySaysSoWithProgress() async {
        let (s, engine, _) = make()
        engine.holdStart = true
        s.startIfPossible()
        engine.push(.downloading(progress: 0.07))
        await until { s.model == .downloading(progress: 0.07) }
        #expect(s.fnPressMessage == "Downloading the speech model, 7%.")
        #expect(!s.isListening)
        engine.release()
        await s.settle()
    }

    @Test func failuresAreSortedIntoTwoActions() async {
        let (s, engine, _) = make()
        engine.startError = ScriptedError(description: "The keyboard event tap could not be created.")
        s.startIfPossible()
        await s.settle()
        #expect(s.failure?.action == .reopen)
        #expect(s.statusLine == s.failure?.message)

        // A failed model load wins over the error text.
        let model = StartFailure.classify(ScriptedError(description: "x"), model: .failed("offline"))
        #expect(model.action == .tryAgain && model.message.contains("speech model"))
        let input = StartFailure.classify(ScriptedError(description: "Saylark needs Input Monitoring (or Accessibility) to hear the Fn key."), model: .notLoaded)
        #expect(input.action == .reopen && input.actionTitle == "Reopen Saylark")
        let other = StartFailure.classify(ScriptedError(description: "disk full"), model: .notLoaded)
        #expect(other.action == .tryAgain && other.actionTitle == "Try Again")
        for f in [model, input, other] { #expect(f.message.hasSuffix(".") && !f.message.contains("Error")) }
    }

    @Test func retryStartsAgainAfterAFailure() async {
        let (s, engine, _) = make()
        engine.startError = ScriptedError(description: "offline")
        s.startIfPossible()
        await s.settle()
        #expect(s.failure != nil)
        #expect(s.fnPressMessage == "Saylark didn't start. Open its menu.")
        engine.startError = nil
        s.retry()
        await s.settle()
        #expect(engine.startCalls == 2 && s.phase == .running)
    }

    @Test func pauseStopsTheEngineAndResumeStartsIt() async {
        let (s, engine, _) = make()
        s.startIfPossible()
        await s.settle()
        s.pause()
        #expect(engine.stopCalls == 1 && s.phase == .paused && s.statusLine == nil && s.fnPressMessage == nil)
        s.startIfPossible()
        #expect(s.phase == .paused, "only resume() leaves a pause")
        s.resume()
        await s.settle()
        #expect(s.phase == .running && engine.startCalls == 2)
    }

    @Test func fakeEngineReportsReadyAtOnce() async {
        let s = EngineSupervisor(engine: FakeEngine(), permissions: FakePermissions())
        s.follow()
        s.startIfPossible()
        await s.settle()
        await until { s.isListening }
        #expect(s.isListening)
    }
}

@MainActor @Suite struct OnboardingFlowTests {
    @Test func engineIsRunningBeforeTheTryItStepEnds() async {
        // First run, everything granted while the user is still on the welcome step.
        let engine = ScriptedEngine()
        let perms = FakePermissions([.microphone: .notDetermined, .inputMonitoring: .notDetermined])
        let supervisor = EngineSupervisor(engine: engine, permissions: perms)
        supervisor.follow()
        let settings = AppSettings(defaults: UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")!)
        let model = OnboardingModel(permissions: perms, supervisor: supervisor, settings: settings)
        model.onRefresh = { supervisor.startIfPossible() }
        model.refresh()
        #expect(engine.startCalls == 0)
        await perms.request(.microphone)
        await perms.request(.inputMonitoring)
        model.refresh()
        await supervisor.settle()
        #expect(engine.startCalls == 1 && supervisor.phase == .running, "no need to press Done first")
        for _ in 0..<5 { model.next() }
        #expect(model.step == .tryIt)
    }

    @Test func windowOpensOnTheStepThatFixesWhatIsMissing() {
        typealias M = OnboardingModel
        #expect(M.firstStep(onboarded: false, missing: []) == .welcome)
        #expect(M.firstStep(onboarded: false, missing: [.microphone]) == .welcome)
        #expect(M.firstStep(onboarded: true, missing: [.microphone, .inputMonitoring]) == .microphone)
        #expect(M.firstStep(onboarded: true, missing: [.inputMonitoring]) == .keyboard)
        #expect(M.firstStep(onboarded: true, missing: [], startFailed: true) == .tryIt)
    }

    @Test func everyRefreshTellsTheApp() {
        let perms = FakePermissions()
        let model = OnboardingModel(permissions: perms)
        var calls = 0
        model.onRefresh = { calls += 1 }
        model.refresh(); model.refresh()
        #expect(calls == 2)
    }
}

@MainActor @Suite struct PillBehaviourTests {
    @Test func theErrorPillIsPlacedEvenWithoutAListenFirst() {
        // An error can be the first event of a take: hidden -> shown must place the panel.
        #expect(LivePill.needsPlacement(wasVisible: false, panelOnScreen: false))
        #expect(LivePill.needsPlacement(wasVisible: false, panelOnScreen: true))
        #expect(LivePill.needsPlacement(wasVisible: true, panelOnScreen: false))
        #expect(!LivePill.needsPlacement(wasVisible: true, panelOnScreen: true), "a live pill stays put when the pointer moves")
    }

    @Test func theModelNotReadyNoticeUsesTheEngineSentence() {
        func width(_ error: PillError) -> CGFloat {
            let v = PillView()
            var m = PillMachine()
            m.handle(.fail(error), at: 0)
            for i in 0..<120 {
                CATransactionScope.run { v.update(state: m.state, time: Double(i) / 120, rms: nil, dt: 1 / 120) }
            }
            return v.pillFrame.width
        }
        let normal = width(.microphoneAccessOff), loading = width(.modelNotReady(message: "Downloading the speech model, 42%."))
        #expect(normal > 0 && loading > 0 && abs(normal - loading) > 4)
    }

    @Test func backingScaleChangesWithTheScreen() {
        let v = PillView(scale: 1)
        #expect(v.backingScale == 1)
        v.setBackingScale(2)
        #expect(v.backingScale == 2)
        var m = PillMachine()
        m.handle(.listen, at: 0)
        CATransactionScope.run { v.update(state: m.state, time: 0, rms: 0.02, dt: 1 / 120) }
        #expect(v.layer.sublayers!.first!.opacity >= 0.45)
        // The stop button's glyph and the message layers carry the new scale.
        func scales(_ l: CALayer) -> [CGFloat] { [l.contentsScale] + (l.sublayers ?? []).flatMap(scales) }
        #expect(scales(v.layer).allSatisfy { $0 == 2 })
    }

    @Test func textCacheIsBounded() {
        let images = TextImages(scale: 2)
        let keep = images.line("keep", size: 13, color: PillMetrics.primary)
        for i in 0..<(TextImages.limit * 3) {
            _ = images.line("word \(i)", size: 13, color: PillMetrics.primary)
            if i % 50 == 0 { _ = images.line("keep", size: 13, color: PillMetrics.primary) }
        }
        #expect(images.count <= TextImages.limit)
        #expect(images.line("keep", size: 13, color: PillMetrics.primary).image === keep.image, "what is in use stays cached")
    }

    @Test func menuGlyphsAreCachedPerState() {
        for s in MenuBarGlyph.State.allCases { #expect(MenuBarGlyph.image(s) === MenuBarGlyph.image(s)) }
        #expect(MenuBarGlyph.image(.idle) !== MenuBarGlyph.image(.paused))
    }

    @Test func micNameFitsThePill() {
        #expect(AudioInputs.pillName("Samson Q2U Microphone") == "Samson Q2U mic")
        #expect(AudioInputs.pillName("MacBook Pro Microphone") == "MacBook Pro mic")
        #expect(AudioInputs.pillName("Q2U") == "Q2U")
        #expect(AudioInputs.pillName("Logitech BRIO Ultra HD Webcam Audio").count <= 23)
        #expect(AudioInputs.pillName("Microphone") == "Microphone")
    }
}

@MainActor @Suite struct AppShellTests {
    @Test func mainMenuHasEditAndWindowShortcuts() {
        let menu = AppMenu.make(target: NSObject(), openMain: Selector(("a")), openSettings: Selector(("b")))
        func keys(_ title: String) -> [String] {
            menu.items.first { $0.title == title }?.submenu?.items.map(\.keyEquivalent) ?? []
        }
        #expect(["x", "c", "v", "a", "z"].allSatisfy(keys("Edit").contains))
        #expect(keys("Window").contains("w") && keys("Window").contains("m"))
        #expect(keys("Saylark").contains("q") && keys("Saylark").contains(","))
        let paste = menu.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.keyEquivalent == "v" }
        #expect(paste?.action == #selector(NSText.paste(_:)) && paste?.target == nil, "goes down the responder chain to the focused field")
    }

    @Test func soundCuesAreShortSoftAndClickFree() {
        for cue in SoundCue.allCases {
            let s = SoundTones.samples(cue)
            let seconds = Double(s.count) / SoundTones.rate
            #expect(seconds > 0.05 && seconds < 0.2)
            #expect((s.map { abs($0) }.max() ?? 1) <= SoundTones.peak + 1e-6)
            #expect(abs(s.first ?? 1) < 0.01 && abs(s.last ?? 1) < 0.01)
            let wav = SoundTones.wav(cue)
            #expect(wav.count == 44 + s.count * 2)
            #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        }
        #expect(SoundTones.samples(.start) != SoundTones.samples(.stop))
    }

    @Test func waveformReadsInChunks() throws {
        // A real file through the chunked reader: the start cue is loudest at the start and fades out.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("saylark-wave-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try SoundTones.wav(.start).write(to: url)
        let bars = try #require(Waveform.bars(audioURL: url, count: 8))
        #expect(bars.count == 8 && bars.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(bars[1] > bars[7])
    }
}

@MainActor @Suite struct LoginItemTests {
    @Test func fakeLoginItemFollowsSetEnabled() throws {
        let item = LoginItem.fake()
        #expect(item.status() == .off)
        try item.setEnabled(true)
        #expect(item.status() == .on)
    }
}
