import Foundation
import Testing
@testable import SaylarkUI
import SaylarkCore

private func suite() -> UserDefaults { UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")! }

@MainActor @Suite struct ActiveSettingsTests {
    @Test func keysAndRawValuesAreTheContract() {
        #expect(AppSettings.Key.triggerKey == "triggerKey")
        #expect(AppSettings.Key.sendOnReturn == "sendOnReturn")
        #expect(AppSettings.Key.sendOnReturnApps == "sendOnReturnApps")
        #expect(AppSettings.Key.paragraphsFromPauses == "paragraphsFromPauses")
        #expect(TriggerKey.allCases.map(\.rawValue) == ["fn", "rightOption", "rightCommand"])
        #expect(SendOnReturn.allCases.map(\.rawValue) == ["off", "listedApps", "everywhere"])
    }

    @Test func writesTheEnumRawValuesUnderTheSharedKeys() {
        let d = suite()
        let s = AppSettings(defaults: d)
        s.triggerKey = .rightCommand
        s.sendOnReturn = .everywhere
        s.paragraphsFromPauses = false
        #expect(d.string(forKey: DictationSettingsKey.triggerKey) == "rightCommand")
        #expect(d.string(forKey: DictationSettingsKey.sendOnReturn) == "everywhere")
        #expect(d.object(forKey: DictationSettingsKey.paragraphsFromPauses) as? Bool == false)
        let again = AppSettings(defaults: d)
        #expect(again.triggerKey == .rightCommand && again.sendOnReturn == .everywhere && !again.paragraphsFromPauses)
    }

    @Test func defaultsAreFnListedAppsAndParagraphsOn() {
        let d = suite()
        let s = AppSettings(defaults: d)
        #expect(s.triggerKey == .fn)
        #expect(s.sendOnReturn == .listedApps)
        #expect(s.paragraphsFromPauses)
        #expect(s.sendOnReturnApps == DictationSettingsKey.defaultSendOnReturnApps)
        // An untouched list is not written, so it keeps following the shipped default.
        #expect(d.object(forKey: DictationSettingsKey.sendOnReturnApps) == nil)
    }

    @Test func editingTheAppListWritesIt() {
        let d = suite()
        let s = AppSettings(defaults: d)
        s.addSendOnReturnApp("com.example.editor")
        s.addSendOnReturnApp("com.example.editor")
        #expect(s.sendOnReturnApps.filter { $0 == "com.example.editor" }.count == 1)
        s.removeSendOnReturnApp("com.openai.chat")
        #expect(d.stringArray(forKey: DictationSettingsKey.sendOnReturnApps) == s.sendOnReturnApps)
        #expect(!s.sendOnReturnApps.contains("com.openai.chat"))
        #expect(AppSettings(defaults: d).sendOnReturnApps == s.sendOnReturnApps)
    }

    @Test func userChoicesAndCopy() {
        #expect(TriggerKey.userChoices == [.fn, .rightOption, .rightCommand])
        #expect(SendOnReturn.explanation == "While you dictate, press Return to stop, paste and send.")
        for text in [SendOnReturn.explanation] + ActiveProblem.problems(in: ActiveReadiness(accessibility: false, clipboard: .wouldAsk, triggerClash: "X")).map(\.sentence) {
            #expect(!text.contains("\u{2014}") && !text.contains("M2") && !text.contains("M3"))
        }
    }
}

@Suite struct ActiveProblemTests {
    @Test func oneSentenceAndOneButtonPerProblem() {
        let r = ActiveReadiness(accessibility: false, clipboard: .wouldAsk, triggerClash: "Wispr Flow")
        let problems = ActiveProblem.problems(in: r)
        #expect(problems == [.triggerClash("Wispr Flow"), .accessibility, .clipboard(.wouldAsk)])
        #expect(problems.map(\.buttonTitle) == ["Use Right Option", "Open Settings", "Allow"])
        #expect(problems[0].sentence == "Wispr Flow is running and also uses Fn, so both would paste. Quit Wispr Flow, or pick another key for Saylark.")
        #expect(ActiveProblem.problems(in: ActiveReadiness()).isEmpty)
        #expect(ActiveProblem.clipboard(.denied).buttonTitle == "Open Settings")
    }

    @MainActor @Test func fixesRunTheRightAction() async {
        let engine = FakeEngine()
        engine.readiness = ActiveReadiness(clipboard: .wouldAsk, triggerClash: "Wispr Flow")
        engine.clipboardAnswer = .allowed
        let perms = FakePermissions([.accessibility: .notDetermined])
        let d = suite()
        let settings = AppSettings(defaults: d)
        let setup = ActiveSetup(engine: engine, permissions: perms, settings: settings)
        #expect(setup.problems.count == 2)
        await setup.fix(.clipboard(.wouldAsk))
        #expect(engine.calls == ["requestClipboardAccess"])
        #expect(setup.readiness.clipboard == .allowed)
        await setup.fix(.triggerClash("Wispr Flow"))
        #expect(settings.triggerKey == .rightOption)
    }
}

@Suite struct MenuModelTests {
    private func record(_ minutesAgo: Double, _ outcome: DictationOutcome, text: String = "hello there", audio: Bool = true, now: Date) -> DictationRecord {
        DictationRecord(startedAt: now.addingTimeInterval(-minutesAgo * 60), duration: 3, mode: .active, handsFree: false,
                        rawText: text, cleanText: text, outcome: outcome, audioPath: audio ? "a.m4a" : nil)
    }

    private func titles(_ m: MenuModel) -> [String] {
        m.entries.compactMap { if case .item(let i) = $0 { i.title } else { nil } }
    }

    @Test func menuHasPasteLastOpenSaylarkAndNoModeSubmenu() {
        let now = Date()
        let m = MenuModel(recent: [record(2, .inserted, now: now)], now: now)
        #expect(titles(m).contains("Copy Last Take") && titles(m).contains("Paste Last Take"))
        #expect(titles(m).contains("Open Saylark") && titles(m).contains("Pause for 1 Hour") && titles(m).contains("Settings…"))
        #expect(m.entries.contains { if case .item(let i) = $0 { i.action == .openSaylark } else { false } })
        #expect(!m.entries.contains { if case .submenu = $0 { true } else { false } })
    }

    @Test func recoverOnlyWhenTheNewestTakeWasCancelledWithin24Hours() {
        let now = Date()
        let cancelled = record(10, .cancelled, now: now)
        #expect(MenuModel.recoverable(in: [cancelled, record(30, .inserted, now: now)], now: now)?.id == cancelled.id)
        #expect(MenuModel.recoverable(in: [record(1, .inserted, now: now), record(30, .cancelled, now: now)], now: now) == nil, "newer take went in")
        #expect(MenuModel.recoverable(in: [record(24 * 60 + 5, .cancelled, now: now)], now: now) == nil, "older than 24 h")
        #expect(MenuModel.recoverable(in: [record(5, .cancelled, text: "", audio: false, now: now)], now: now) == nil, "nothing to recover")
        #expect(MenuModel.recoverable(in: [record(5, .cancelled, text: "", audio: true, now: now)], now: now) != nil, "audio is enough")
        let m = MenuModel(recent: [cancelled], now: now)
        #expect(m.entries.contains { if case .item(let i) = $0, case .recover(cancelled.id)? = i.action { true } else { false } })
    }

    @Test func lastTranscriptSkipsCancelledFailedAndEmpty() {
        let now = Date()
        let good = record(20, .inserted, now: now)
        let recs = [record(1, .cancelled, now: now), record(2, .failed, text: "", now: now), record(3, .empty, text: "", now: now), good]
        #expect(MenuModel.lastTranscript(in: recs)?.id == good.id)
        let none = MenuModel(recent: [], now: now)
        #expect(titles(none).first == "No takes yet")
    }

    @Test func pausedMenuOffersResume() {
        let now = Date()
        let m = MenuModel(recent: [], now: now, pausedUntil: now.addingTimeInterval(600), timeFormat: { _ in "3:30 PM" })
        #expect(titles(m).contains("Resume"))
        #expect(!titles(m).contains("Pause for 1 Hour"))
        #expect(m.entries.contains { if case .item(let i) = $0 { i.subtitle == "Paused until 3:30 PM" } else { false } })
    }

    @MainActor @Test func glyphPrioritisesListeningThenPausedThenProblem() {
        #expect(MenuModel.glyph(listening: true, paused: true, problem: true) == .listening)
        #expect(MenuModel.glyph(listening: false, paused: true, problem: true) == .paused)
        #expect(MenuModel.glyph(listening: false, paused: false, problem: true) == .problem)
        #expect(MenuModel.glyph(listening: false, paused: false, problem: false) == .idle)
        let images = MenuBarGlyph.State.allCases.map { MenuBarGlyph.image($0) }
        #expect(Set(images.map(ObjectIdentifier.init)).count == images.count)
        #expect(MenuBarGlyph.image(.idle) === MenuBarGlyph.image(.idle))
    }
}

@Suite struct TakeRowStateTests {
    private func r(_ outcome: DictationOutcome, text: String = "hi", sent: Bool = false, recovered: Bool = false, audio: Bool = true) -> DictationRecord {
        var rec = DictationRecord(startedAt: Date(), duration: 2, mode: .active, handsFree: false, rawText: text, cleanText: text,
                                  outcome: outcome, audioPath: audio ? "a.m4a" : nil, recovered: recovered)
        rec.sent = sent
        return rec
    }

    @Test func eachOutcomeHasItsOwnMark() {
        #expect(TakeRowState.of(r(.inserted)).kind == .inserted)
        #expect(TakeRowState.of(r(.inserted)).label == nil)
        #expect(TakeRowState.of(r(.inserted, sent: true)).kind == .sent)
        #expect(TakeRowState.of(r(.inserted, sent: true)).label == "Sent")
        #expect(TakeRowState.of(r(.card)).label == "Not pasted")
        #expect(TakeRowState.of(r(.cancelled)).label == "Cancelled")
        #expect(TakeRowState.of(r(.failed, text: "")).label == "Couldn't transcribe")
        #expect(TakeRowState.of(r(.logged)).label == nil)
        #expect(TakeRowState.of(r(.inserted, recovered: true)).recovered)
    }

    @Test func recoverAndTranscribeAgain() {
        #expect(TakeRowState.of(r(.cancelled)).canRecover)
        #expect(TakeRowState.of(r(.cancelled, text: "", audio: true)).canRecover)
        #expect(!TakeRowState.of(r(.cancelled, text: "", audio: false)).canRecover)
        #expect(TakeRowState.of(r(.failed, text: "")).canTranscribeAgain)
        #expect(!TakeRowState.of(r(.failed, text: "", audio: false)).canTranscribeAgain)
        #expect(!TakeRowState.of(r(.inserted)).canTranscribeAgain)
        #expect(TakeRowState.of(r(.failed, text: "")).placeholder != nil)
        #expect(TakeRowState.of(r(.inserted)).placeholder == nil)
    }

    @Test func hoverActionsFollowContent() {
        #expect(TakeRowState.of(r(.inserted)).hoverActions == [.copy, .pasteAgain, .play])
        #expect(TakeRowState.of(r(.logged)).hoverActions == [.copy, .pasteAgain, .play])
        #expect(TakeRowState.of(r(.inserted, audio: false)).hoverActions == [.copy, .pasteAgain])
        #expect(TakeRowState.of(r(.cancelled)).hoverActions == [.copy, .play])
        #expect(TakeRowState.of(r(.failed, text: "")).hoverActions == [.play])
    }

    @Test func statsHeaderMinutes() {
        #expect(StatsHeader.minutes(0) == "0")
        #expect(StatsHeader.minutes(0.84) == "0.8")
        #expect(StatsHeader.minutes(12.4) == "12")
    }
}

@MainActor @Suite struct ActiveLibraryTests {
    @Test func sampleHistoryCoversEveryRowState() {
        let kinds = Set(SampleTakes.history().map { TakeRowState.of($0).kind })
        #expect(kinds.isSuperset(of: [.inserted, .sent, .card, .copied, .cancelled, .failed]))
        #expect(SampleTakes.history().contains { $0.recovered })
    }

    @Test func pasteAgainAndRecoverGoThroughTheEngine() async {
        let engine = FakeEngine(history: FakeHistory(SampleTakes.history()))
        let model = LibraryModel(history: engine.history)
        model.engine = engine
        model.pasteDelay = .milliseconds(1)
        var yielded = 0
        model.yieldFocus = { yielded += 1 }
        await model.load()
        let take = model.all[2]
        model.pasteAgain(take)
        await until { model.flash[take.id] != nil }
        #expect(model.flash[take.id] == "Pasted")
        #expect(yielded == 1)
        let cancelled = model.all.first { $0.outcome == .cancelled && $0.cleanText.isEmpty }!
        model.recover(cancelled)
        await until { model.flash[cancelled.id] != nil }
        #expect(engine.calls.contains("retranscribe"))
        #expect(model.flash[cancelled.id] == "Pasted")
    }

    @Test func transcribeAgainUpdatesTheRow() async {
        let engine = FakeEngine(history: FakeHistory(SampleTakes.history()))
        let model = LibraryModel(history: engine.history)
        model.engine = engine
        await model.load()
        let failed = model.all.first { $0.outcome == .failed }!
        model.transcribeAgain(failed)
        await until { model.all.first { $0.id == failed.id }?.outcome != .failed }
        let after = model.all.first { $0.id == failed.id }!
        #expect(!after.cleanText.isEmpty)
    }

    @Test func pasteWithoutPermissionReportsTheCard() async {
        let engine = FakeEngine(history: FakeHistory(SampleTakes.history()))
        engine.readiness = ActiveReadiness(accessibility: false)
        let outcome = await engine.paste(SampleTakes.history()[0].id)
        #expect(outcome == .card)
    }
}

@MainActor @Suite struct FakeEngineCardFlowTests {
    private func drain(_ engine: FakeEngine, until stop: @escaping (DictationEvent) -> Bool) async -> [DictationEvent] {
        var seen: [DictationEvent] = []
        for await e in engine.events {
            seen.append(e)
            if stop(e) { break }
        }
        return seen
    }

    @Test func noFieldTakeShowsCardThenCopyOrPasteOrDismiss() async {
        let engine = FakeEngine()
        engine.playTake(ending: .noField)
        let events = await drain(engine) { if case .saved = $0 { true } else { false } }
        #expect(events.contains { if case .pill(.finish(.noTextFieldCopied), _) = $0 { true } else { false } })
        #expect(events.contains { if case .saved(let r) = $0 { r.outcome == .copied } else { false } }, "copied for the user at once")

        engine.cardCopy()
        #expect(engine.calls == ["cardCopy"])
        let after = await drain(engine) { if case .saved = $0 { true } else { false } }
        #expect(after.contains { $0 == .pill(.copied) })
        let saved = try? await engine.history.recent(limit: 1, before: nil)
        #expect(saved?.first?.outcome == .copied)
    }

    @Test func missingPermissionsRenderAsCardReasons() async {
        for (readiness, reason) in [(ActiveReadiness(accessibility: false), CardReason.accessibilityOff),
                                    (ActiveReadiness(clipboard: .denied), CardReason.clipboardNotAllowed)] {
            let engine = FakeEngine()
                engine.readiness = readiness
            engine.playTake()
            let events = await drain(engine) { if case .saved = $0 { true } else { false } }
            #expect(events.contains { if case .pill(.finish(.cannotPaste(_, let r)), _) = $0 { r == reason } else { false } })
        }
    }

    @Test func pasteWhenFieldFocusesThenInserts() async {
        let engine = FakeEngine()
        engine.fieldFocusDelay = 0.01
        engine.playTake(ending: .noField)
        _ = await drain(engine) { if case .saved = $0 { true } else { false } }
        engine.cardPasteWhenField()
        let after = await drain(engine) { if case .saved = $0 { true } else { false } }
        #expect(after.contains { $0 == .pill(.fieldFocused) })
    }

    @Test func clipboardRequestReportsTheScriptedAnswer() async {
        let engine = FakeEngine()
        engine.readiness = ActiveReadiness(clipboard: .wouldAsk)
        engine.clipboardAnswer = .denied
        let state = await engine.requestClipboardAccess()
        #expect(state == .denied)
        #expect(engine.activeReadiness().clipboard == .denied)
        #expect(!engine.activeReadiness().canPaste)
    }
}

@MainActor @Suite struct OnboardingStepsTests {
    private func settings() -> AppSettings { AppSettings(defaults: suite()) }

    @Test func everyStepIncludingAccessibilityAndClipboard() {
        #expect(OnboardingModel(permissions: FakePermissions()).steps == [.welcome, .microphone, .keyboard, .accessibility, .clipboard, .tryIt])
    }

    @Test func nextAndBackWalkTheSteps() {
        let m = OnboardingModel(permissions: FakePermissions([.inputMonitoring: .notDetermined]), step: .keyboard, settings: settings())
        m.next()
        #expect(m.step == .accessibility)
        m.back()
        #expect(m.step == .keyboard)
    }

    @Test func clipboardStepMovesOnWhenAllowed() async {
        let engine = FakeEngine()
        engine.readiness = ActiveReadiness(clipboard: .wouldAsk)
        engine.clipboardAnswer = .allowed
        let setup = ActiveSetup(engine: engine, permissions: FakePermissions())
        let m = OnboardingModel(permissions: FakePermissions(), step: .clipboard, settings: settings(), setup: setup)
        #expect(m.clipboard == .wouldAsk && !m.clipboardNeedsSettings)
        m.requestClipboard()
        await until { m.clipboard == .allowed }
        #expect(engine.calls == ["requestClipboardAccess"])
        await until { m.step == .tryIt }
        #expect(m.step == .tryIt)
    }

    @Test func aClipboardAnswerThatIsNotAllowShowsWhereToChangeIt() async {
        let engine = FakeEngine()
        engine.readiness = ActiveReadiness(clipboard: .wouldAsk)
        engine.clipboardAnswer = .wouldAsk
        let setup = ActiveSetup(engine: engine, permissions: FakePermissions())
        let m = OnboardingModel(permissions: FakePermissions(), step: .clipboard, settings: settings(), setup: setup)
        m.requestClipboard()
        await until { setup.clipboardAsked }
        #expect(m.clipboardNeedsSettings)
    }

    @Test func clashOnFnOffersAnotherKey() {
        let s = settings()
        let setup = ActiveSetup.preview(ActiveReadiness(triggerClash: "Wispr Flow"))
        let m = OnboardingModel(permissions: FakePermissions(), step: .tryIt, settings: s, setup: setup)
        #expect(m.triggerClash == "Wispr Flow")
        m.useRightOption()
        #expect(s.triggerKey == .rightOption)
        #expect(m.triggerClash == nil)
    }

    @Test func firstStepSendsAnOnboardedUserToTheMissingAccessibility() {
        #expect(OnboardingModel.firstStep(onboarded: true, missing: [.accessibility]) == .accessibility)
        #expect(OnboardingModel.firstStep(onboarded: false, missing: []) == .welcome)
    }
}
