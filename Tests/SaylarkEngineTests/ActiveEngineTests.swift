import AppKit
import Foundation
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// Active mode end to end: scripted trigger key, fake mic, fake recognizer, and the real
/// `Inserter` over an in-memory clipboard, a recording key poster and scripted focus. Nothing
/// touches the real clipboard, keyboard or accessibility.
@MainActor @Suite struct ActiveEngineTests {
    static let user = PasteboardSnapshot.Item([.init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("USER CLIPBOARD".utf8)),
                                               .init(type: "public.rtf", data: Data("{\\rtf1 USER}".utf8))])
    static let field = FocusInfo(kind: .editableText, engine: .web, pid: 100, caret: .init(before: "", after: ""))
    static let button = FocusInfo(kind: .notText, engine: .native, pid: 100)

    static var fast: InsertionMachine.Config {
        var c = InsertionMachine.Config()
        c.quietAfterRead = 0.02
        c.minHoldAfterKey = 0.03
        c.readTimeout = 0.5
        c.holdWhenReadBeforeKey = 0.1
        c.fieldWaitTimeout = 3
        return c
    }

    /// The pretend target app: its text field, and when things happened to it.
    @MainActor final class Target {
        var field = ""
        var sent: [String] = []
        var log: [(String, Double)] = []
        func note(_ s: String) { log.append((s, HotkeyClock.now)) }
        func time(of s: String) -> Double? { log.first { $0.0 == s }?.1 }
    }

    @MainActor final class Log {
        var events: [DictationEvent] = []
        var notices: [EngineNotice] = []
        var saved: [DictationRecord] { events.compactMap { if case .saved(let r) = $0 { r } else { nil } } }
        var pills: [(PillEvent, UUID?)] { events.compactMap { if case .pill(let e, let t) = $0, !Self.isWords(e) { (e, t) } else { nil } } }
        static func isWords(_ e: PillEvent) -> Bool { if case .words = e { true } else { false } }
        func last(_ id: UUID) -> DictationRecord? { saved.last { $0.id == id } }
    }

    struct Rig {
        let engine: ShadowEngine
        let pb: MemoryPasteboard
        let keys: RecordingKeyPoster
        let probe: ScriptedFocusProbe
        let tap: ScriptedReturnTap
        let target: Target
        let log: Log
        let defaults: UserDefaults
    }

    static let speech = FakeSpeech.samples(words: 0..<8)  // about 3.6 s
    static var talk: Double { Double(speech.count) / 16_000 }

    static func rig(
        steps: [(Double, ScriptedFnSource.Step)], focus: [FocusInfo] = [field],
        clipboard: InsertionMachine.ClipboardAccess = .allowed, canPostKeys: Bool = true, targetReads: Bool = true,
        tap: ScriptedReturnTap = ScriptedReturnTap(), running: [String] = [], app: String = "com.example.test",
        loadDelay: Duration = .zero, cardTimeout: Double = 120, settings: (UserDefaults) -> Void = { _ in }
    ) throws -> Rig {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saylark-active-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "saylark.test.\(UUID().uuidString)")!
        settings(defaults)
        let fn = ScriptedFnSource(steps, returnTap: tap)
        let mic = FakeAudioSource(samples: speech, pace: .realtime, startDelay: 0.02, name: "Fake Q2U")
        let recognizer = FakeRecognizer(), voice = FakeVoice()
        let pb = MemoryPasteboard(items: [user])
        pb.access = clipboard
        let keys = RecordingKeyPoster()
        let target = Target()
        keys.onPaste = { _ in
            target.note("paste")
            guard targetReads else { return }
            // A real app reads the clipboard a moment after ⌘V.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                MainActor.assumeIsolated {
                    target.note("read")
                    target.field += pb.readString() ?? ""
                }
            }
        }
        keys.onReturn = { _ in
            target.note("return")
            target.sent.append(target.field)
        }
        let probe = ScriptedFocusProbe(focus)
        let config = fast
        var parts = ShadowEngine.Parts(
            makeFnSource: { fn }, makeAudioSource: { mic }, historyFolder: folder, defaults: defaults,
            frontmostApp: { (app, "Test") },
            loadModels: { _ in
                if loadDelay > .zero { try await Task.sleep(for: loadDelay) }
                return (recognizer, voice)
            })
        parts.fnCheckInterval = 0.2
        parts.cardTimeout = cardTimeout
        parts.makeInserter = {
            Inserter(parts: .init(pasteboard: pb, keys: keys, focus: probe, watcher: PollingFieldWatcher(probe: probe, interval: 0.02),
                                  accessibility: RecordingAccessibilityInserter(result: false),
                                  environment: { .init(clipboard: pb.access, canPostKeys: canPostKeys) }),
                     config: config)
        }
        parts.makeReturnInterceptor = { tap }
        parts.runningApps = { running }
        let engine = try ShadowEngine(parts: parts)
        let log = Log()
        Task { @MainActor in for await e in engine.events { log.events.append(e) } }
        Task { @MainActor in for await n in engine.notices { log.notices.append(n) } }
        return Rig(engine: engine, pb: pb, keys: keys, probe: probe, tap: tap, target: target, log: log, defaults: defaults)
    }

    static func hold(_ at: Double = 0.1, _ length: Double = talk + 0.5) -> [(Double, ScriptedFnSource.Step)] {
        [(at, .fnDown), (at + length, .fnUp)]
    }

    static func handsFree(_ at: Double = 0.1, stopAfter talk: Double = talk + 0.4, stop: ScriptedFnSource.Step = .fnDown) -> [(Double, ScriptedFnSource.Step)] {
        var s: [(Double, ScriptedFnSource.Step)] = [(at, .fnDown), (at + 0.08, .fnUp), (at + 0.2, .fnDown), (at + 0.28, .fnUp), (at + talk, stop)]
        if stop == .fnDown { s.append((at + talk + 0.08, .fnUp)) }
        return s
    }

    /// Waits up to `seconds` for `done`; on timeout the test fails, naming what it waited for.
    func soon(_ seconds: Double, _ what: String, sourceLocation: SourceLocation = #_sourceLocation, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() >= end {
                Issue.record("Timed out after \(seconds) s waiting for: \(what)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// `waitForTakes`, bounded: every take saved and its insertion settled within `seconds`.
    func settled(_ rig: Rig, _ seconds: Double = 10, sourceLocation: SourceLocation = #_sourceLocation) async {
        await soon(seconds, "every take saved and its insertion settled (inflight \(rig.engine.inflight.count), settling \(rig.engine.settling.count))",
                   sourceLocation: sourceLocation) { rig.engine.inflight.isEmpty && rig.engine.settling.isEmpty }
    }

    func clipboardText(_ pb: MemoryPasteboard) -> String? {
        pb.items.first?.data(NSPasteboard.PasteboardType.string.rawValue).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: Pasting

    @Test func holdPastesTheTextAndPutsTheClipboardBack() async throws {
        let rig = try Self.rig(steps: Self.hold())
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        await settled(rig)
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .inserted)
        #expect(r.mode == .active)
        #expect(!r.sent)
        #expect(rig.target.field == FakeSpeech.text(0..<8) + " ")
        #expect(rig.keys.log == [.paste(100)])
        #expect(rig.pb.items == [Self.user])  // the user's clipboard came back intact
        #expect(rig.log.pills.map(\.0) == [.listen, .finish(.inserted)])
        #expect(rig.log.pills.allSatisfy { $0.1 == r.id })
        // The paste happened before the take was saved (no waiting on the m4a encode).
        let finishIndex = rig.log.events.firstIndex { if case .pill(.finish, _) = $0 { true } else { false } }
        let savedIndex = rig.log.events.firstIndex { if case .saved = $0 { true } else { false } }
        #expect(finishIndex! < savedIndex!)
        // Active release→text means release → ⌘V posted.
        let m = try #require(try await rig.engine.store.metrics(for: r.id)?.insertion)
        #expect(m.outcome == "pasted")
        #expect(r.releaseToTextMs == m.releaseToPasteMs)
        #expect(m.textMs != nil && m.releaseToPasteMs! >= m.textMs!)
        #expect(m.readConfirmed == true)
        #expect(m.clipboard == "restored")
        #expect(m.restoreMs != nil)
        rig.engine.stop()
    }

    @Test func noTextFieldCopiesTheTextAndTheCardSaysSo() async throws {
        let rig = try Self.rig(steps: Self.hold(), focus: [Self.button]) { $0.set(true, forKey: DictationSettingsKey.copyWhenNoField) }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        let text = FakeSpeech.text(0..<8)
        #expect(r.outcome == .copied)
        #expect(r.cleanText == text)
        #expect(rig.keys.posts.isEmpty)
        #expect(rig.log.pills.map(\.0) == [.listen, .finish(.noTextFieldCopied(text))])
        await soon(2, "notice .card(take: r.id, cause: .noTextField)") { rig.log.notices.contains(.card(take: r.id, cause: .noTextField)) }
        #expect(clipboardText(rig.pb) == text, "on the clipboard at once, like Wispr Flow")
        rig.engine.cardDismiss()
        await settled(rig)
        #expect(clipboardText(rig.pb) == text, "and it stays there")
        rig.engine.stop()
    }

    @Test func noTextFieldWithCopyOffShowsTheCardAndCopyWorks() async throws {
        let rig = try Self.rig(steps: Self.hold(), focus: [Self.button]) { $0.set(false, forKey: DictationSettingsKey.copyWhenNoField) }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        let text = FakeSpeech.text(0..<8)
        #expect(r.outcome == .card)
        #expect(rig.log.pills.map(\.0) == [.listen, .finish(.noTextField(text))])
        await soon(2, "notice .card(take: r.id, cause: .noTextField)") { rig.log.notices.contains(.card(take: r.id, cause: .noTextField)) }
        #expect(rig.pb.items == [Self.user])  // copy off: the card does not copy by itself
        rig.engine.cardCopy()
        await soon(2, "Copied on the pill") { rig.log.pills.last?.0 == .copied }
        await soon(5, "rig.log.last(r.id)?.outcome == .copied") { rig.log.last(r.id)?.outcome == .copied }
        #expect(rig.log.last(r.id)?.outcome == .copied)
        #expect(clipboardText(rig.pb) == text)
        #expect(try await rig.engine.store.record(r.id)?.outcome == .copied)
        rig.engine.cardDismiss()
        rig.engine.stop()
    }

    @Test func pasteWhenIClickAFieldLandsLater() async throws {
        let rig = try Self.rig(steps: Self.hold(), focus: [Self.button]) { $0.set(true, forKey: DictationSettingsKey.copyWhenNoField) }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        rig.engine.cardPasteWhenField()
        try await Task.sleep(for: .milliseconds(100))
        rig.probe.set([FocusInfo(kind: .editableText, engine: .web, pid: 100, elementID: 7, caret: .init(before: "", after: ""))])
        await soon(5, "rig.log.last(r.id)?.outcome == .inserted") { rig.log.last(r.id)?.outcome == .inserted }
        #expect(rig.log.pills.map(\.0).contains(.fieldFocused))
        await soon(2, "the text in the target field") { rig.target.field.hasPrefix(FakeSpeech.text(0..<8)) }
        #expect(try await rig.engine.store.record(r.id)?.outcome == .inserted)
        await settled(rig)
        // The text was copied when the card came up; the paste's restore puts that back.
        #expect(clipboardText(rig.pb) == FakeSpeech.text(0..<8))
        rig.engine.stop()
    }

    /// No Accessibility: the take is still transcribed and saved; the pill shows the card and the
    /// notice says why.
    @Test func noAccessibilityStillKeepsTheWords() async throws {
        let rig = try Self.rig(steps: Self.hold(), canPostKeys: false)
        #expect(rig.engine.activeReadiness().accessibility == false)
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .card)
        #expect(r.cleanText == FakeSpeech.text(0..<8))
        #expect(rig.keys.posts.isEmpty)
        #expect(rig.log.pills.last?.0 == .finish(.cannotPaste(FakeSpeech.text(0..<8), reason: .accessibilityOff)))
        await soon(2, "notice .card(take: r.id, cause: .accessibilityOff)") { rig.log.notices.contains(.card(take: r.id, cause: .accessibilityOff)) }
        #expect(rig.engine.store.audioURL(for: r) != nil)
        rig.engine.cardDismiss()
        rig.engine.stop()
    }

    /// The clipboard can't be read without the macOS prompt: never paste over it; card instead.
    @Test func blockedClipboardIsNeverOverwritten() async throws {
        let rig = try Self.rig(steps: Self.hold(), clipboard: .wouldPrompt)
        #expect(rig.engine.activeReadiness().clipboard == .wouldAsk)
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .card)
        #expect(rig.pb.snapshotReads == 0)
        #expect(rig.pb.items == [Self.user])
        #expect(rig.keys.posts.isEmpty)
        #expect(rig.log.pills.last?.0 == .finish(.cannotPaste(FakeSpeech.text(0..<8), reason: .clipboardNotAllowed)))
        await soon(2, "notice .card(take: r.id, cause: .clipboardBlocked)") { rig.log.notices.contains(.card(take: r.id, cause: .clipboardBlocked)) }
        rig.engine.cardDismiss()
        rig.engine.stop()
    }

    @Test func cardTheAppNeverClosesStillSettles() async throws {
        let rig = try Self.rig(steps: Self.hold(), focus: [Self.button], cardTimeout: 0.5)
        try await rig.engine.start()
        await soon(10, "the take saved") { !rig.log.saved.isEmpty }
        await settled(rig, 5)
        #expect(rig.log.pills.last?.0 == .dismiss)
        #expect(rig.engine.card == nil)
        rig.engine.stop()
    }

    /// A paste from the menu with no field: no card (the pill is not up), the take keeps its text.
    @Test func pasteFromTheMenuWithNoFieldLeavesNothingWaiting() async throws {
        let steps: [(Double, ScriptedFnSource.Step)] = [(0.1, .fnDown), (Self.talk + 0.5, .escape), (Self.talk + 0.6, .fnUp)]
        let rig = try Self.rig(steps: steps)
        try await rig.engine.start()
        await soon(10, "the cancelled take saved") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        rig.probe.set([Self.button])
        #expect(await rig.engine.paste(r.id) == .card)
        #expect(rig.engine.card == nil)
        await soon(2, "the no-field card notice") { rig.log.notices.contains(.card(take: r.id, cause: .noTextField)) }
        await settled(rig, 5)
        #expect(rig.pb.items == [Self.user])
        rig.engine.stop()
    }

    // MARK: Dictate and send

    @Test func returnInHandsFreePastesThenSendsAfterTheRead() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stop: .returnKey)) { $0.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn) }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        await settled(rig)
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .inserted)
        #expect(r.sent)
        #expect(try await rig.engine.store.record(r.id)?.sent == true)
        #expect(rig.keys.log == [.paste(100), .returnKey(100)])
        #expect(rig.tap.swallowed.count == 1)
        #expect(rig.tap.passedThrough.isEmpty)
        // Return strictly after the target read the text, and the text was in the field.
        let read = try #require(rig.target.time(of: "read")), sent = try #require(rig.target.time(of: "return"))
        #expect(sent > read)
        #expect(rig.target.sent == [FakeSpeech.text(0..<8) + " "])
        #expect(rig.pb.items == [Self.user])
        let m = try #require(try await rig.engine.store.metrics(for: r.id)?.insertion)
        #expect(m.returnArmed == true && m.sendRequested == true)
        #expect(m.releaseToReturnMs != nil)
        #expect(!rig.tap.isArmed)  // disarmed once the take ended
        rig.engine.stop()
    }

    @Test func returnDuringAHoldSends() async throws {
        let steps: [(Double, ScriptedFnSource.Step)] = [(0.1, .fnDown), (Self.talk + 0.2, .returnKey), (Self.talk + 0.35, .fnUp)]
        let rig = try Self.rig(steps: steps, app: "com.anthropic.claudefordesktop")  // in the default list
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        await settled(rig)
        let r = try #require(rig.log.saved.first)
        #expect(r.sent)
        #expect(rig.keys.log == [.paste(100), .returnKey(100)])
        #expect(rig.log.saved.count == 1)
        rig.engine.stop()
    }

    /// An app not in the list: Return is not intercepted, reaches the app, and the take goes on.
    @Test func returnOutsideTheListedAppsReachesTheApp() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stopAfter: Self.talk + 0.8) + [(2.0, .returnKey)])
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        await settled(rig)
        let r = try #require(rig.log.saved.first)
        #expect(!r.sent)
        #expect(r.outcome == .inserted)
        #expect(r.duration > Self.talk)  // Return did not end the take
        #expect(rig.tap.armCount == 0)
        #expect(rig.tap.passedThrough.count == 1)
        #expect(rig.keys.returns.isEmpty)
        rig.engine.stop()
    }

    @Test func shiftReturnPassesThrough() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stopAfter: Self.talk + 0.8) + [(2.0, .shiftReturn)]) {
            $0.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn)
        }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(!r.sent)
        #expect(rig.tap.armCount == 1)
        #expect(rig.tap.passedThrough.count == 1)
        #expect(rig.tap.swallowed.isEmpty)
        #expect(rig.keys.returns.isEmpty)
        rig.engine.stop()
    }

    /// The consuming tap could not be installed: Return passes through once, nothing is sent.
    @Test func tapThatCannotInstallFailsSafe() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stopAfter: Self.talk + 0.8) + [(2.0, .returnKey)], tap: ScriptedReturnTap(installFails: true)) {
            $0.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn)
        }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        await settled(rig)
        let r = try #require(rig.log.saved.first)
        #expect(!r.sent)
        #expect(r.duration > Self.talk)
        #expect(rig.tap.passedThrough.count == 1)
        #expect(rig.keys.returns.isEmpty)
        #expect(try await rig.engine.store.metrics(for: r.id)?.insertion?.returnArmed == false)
        rig.engine.stop()
    }

    /// The system disabled the tap mid-take: same as never installed.
    @Test func tapDisabledBySystemFailsSafe() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stopAfter: Self.talk + 0.8) + [(2.0, .returnKey)], tap: ScriptedReturnTap(disabledAfter: 0.5)) {
            $0.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn)
        }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(!r.sent)
        #expect(rig.tap.passedThrough.count == 1)
        #expect(rig.keys.returns.isEmpty)
        rig.engine.stop()
    }

    @Test func noFieldMeansNoReturn() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stop: .returnKey), focus: [Self.button]) {
            $0.set(true, forKey: DictationSettingsKey.copyWhenNoField)
            $0.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn)
        }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .copied)  // no field: copied for the user, never sent
        #expect(!r.sent)
        #expect(rig.keys.log.isEmpty)
        await soon(2, "notice .sendSkipped(take: r.id, why: .card)") { rig.log.notices.contains(.sendSkipped(take: r.id, why: .card)) }
        rig.engine.cardDismiss()
        rig.engine.stop()
    }

    /// The paste was never read: no Return (it would send the box without the text).
    @Test func unreadPasteMeansNoReturn() async throws {
        let rig = try Self.rig(steps: Self.handsFree(stop: .returnKey), targetReads: false) {
            $0.set(SendOnReturn.everywhere.rawValue, forKey: DictationSettingsKey.sendOnReturn)
        }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(!r.sent)
        #expect(rig.keys.returns.isEmpty)
        await soon(2, "notice .sendSkipped(take: r.id, why: .notRead)") { rig.log.notices.contains(.sendSkipped(take: r.id, why: .notRead)) }
        await soon(5, "pasteFailed on the pill") { rig.log.pills.contains { $0.0 == .fail(.pasteFailed) } }
        await soon(5, "outcome .card after the unread paste") { rig.log.last(r.id)?.outcome == .card }
        await soon(2, "notice .pasteFailed(take: r.id)") { rig.log.notices.contains(.pasteFailed(take: r.id)) }
        await settled(rig)
        #expect(rig.pb.items == [Self.user])
        rig.engine.stop()
    }

    // MARK: Trigger keys

    @Test(arguments: [TriggerKey.rightOption, .rightCommand])
    func rightHandTriggersWork(trigger: TriggerKey) async throws {
        let rig = try Self.rig(steps: Self.hold()) { $0.set(trigger.rawValue, forKey: DictationSettingsKey.triggerKey) }
        #expect(rig.engine.triggerKey == trigger)
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .inserted)
        rig.engine.stop()
    }

    @Test(arguments: TriggerKey.allCases)
    func leftHandTwinNeverStartsATake(trigger: TriggerKey) async throws {
        let rig = try Self.rig(steps: [(0.1, .leftTwinDown), (2.0, .leftTwinUp)]) { $0.set(trigger.rawValue, forKey: DictationSettingsKey.triggerKey) }
        try await rig.engine.start()
        try await Task.sleep(for: .seconds(2.5))
        #expect(rig.log.events.isEmpty)
        #expect(rig.log.saved.isEmpty)
        rig.engine.stop()
    }

    /// The stuck-key check works for right Option too.
    @Test func lostReleaseOfRightOptionDoesNotLeaveTheTakeStuck() async throws {
        let rig = try Self.rig(steps: [(0.1, .fnDown), (1.5, .fnUpLost)]) { $0.set(TriggerKey.rightOption.rawValue, forKey: DictationSettingsKey.triggerKey) }
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.duration < 1.9)
        rig.engine.stop()
    }

    /// A trigger change arrives mid-take: the take finishes on the old key, the next uses the new.
    @Test func triggerChangeAppliesBetweenTakes() async throws {
        let rig = try Self.rig(steps: Self.hold(0.1, 1.5))
        try await rig.engine.start()
        try await Task.sleep(for: .seconds(0.6))
        rig.defaults.set(TriggerKey.rightCommand.rawValue, forKey: DictationSettingsKey.triggerKey)
        try await Task.sleep(for: .seconds(0.2))
        #expect(rig.engine.triggerKey == .fn)  // a take is running
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        #expect(rig.log.saved.count == 1)
        await soon(2, "rig.engine.triggerKey == .rightCommand") { rig.engine.triggerKey == .rightCommand }
        #expect(rig.engine.triggerKey == .rightCommand)
        rig.engine.stop()
    }

    // MARK: Readiness, model

    @Test func readinessReportsAClashingDictationApp() async throws {
        let rig = try Self.rig(steps: [], clipboard: .wouldPrompt, running: ["com.apple.finder", "com.electron.wispr-flow"])
        var ready = rig.engine.activeReadiness()
        #expect(ready.triggerClash == "Wispr Flow")
        #expect(ready.clipboard == .wouldAsk)
        #expect(!ready.canPaste)
        #expect(await rig.engine.requestClipboardAccess() == .allowed)
        #expect(rig.pb.accessRequests == 1)
        rig.defaults.set(TriggerKey.rightOption.rawValue, forKey: DictationSettingsKey.triggerKey)
        try await rig.engine.start()  // applies settings
        ready = rig.engine.activeReadiness()
        #expect(ready.triggerClash == nil)
        #expect(ready.canPaste)
        rig.engine.stop()
    }

    @Test func pressBeforeTheModelIsReadySaysSo() async throws {
        // A hands-free double tap while loading: one notice, no hands-free pill with no take.
        let rig = try Self.rig(steps: Self.handsFree(0.2, stopAfter: 1.0), loadDelay: .seconds(2))
        try await rig.engine.start()
        await soon(2, "the not-ready notice") { rig.log.notices.contains { if case .modelNotReady = $0 { true } else { false } } }
        #expect(rig.log.pills.contains { if case .fail(.modelNotReady(let message)) = $0.0 { message == "Still getting ready. Try again in a moment." } else { false } })
        #expect(rig.log.saved.isEmpty)
        #expect(!rig.log.pills.contains { $0.0 == .lockHandsFree || $0.0 == .listen })
        rig.engine.stop()
    }

    // MARK: Cancelled takes and paste

    @Test func cancelledTakeIsTranscribedAndCanBePasted() async throws {
        let steps: [(Double, ScriptedFnSource.Step)] = [(0.1, .fnDown), (Self.talk + 0.5, .escape), (Self.talk + 0.6, .fnUp)]
        let rig = try Self.rig(steps: steps)
        try await rig.engine.start()
        await soon(10, "!rig.log.saved.isEmpty") { !rig.log.saved.isEmpty }
        let r = try #require(rig.log.saved.first)
        #expect(r.outcome == .cancelled)
        #expect(r.cleanText == FakeSpeech.text(0..<8))
        #expect(rig.keys.posts.isEmpty)
        #expect(rig.log.pills.map(\.0) == [.listen, .cancel])
        #expect(await rig.engine.paste(r.id) == .inserted)
        await soon(2, "the text in the target field") { rig.target.field.hasPrefix(FakeSpeech.text(0..<8)) }
        await soon(5, "rig.log.last(r.id)?.outcome == .inserted") { rig.log.last(r.id)?.outcome == .inserted }
        #expect(try await rig.engine.store.record(r.id)?.outcome == .inserted)
        rig.engine.stop()
    }

    /// `paste` right after Esc waits for the background transcription instead of failing.
    @Test func pasteRightAfterCancelWaitsForTheText() async throws {
        let steps: [(Double, ScriptedFnSource.Step)] = [(0.1, .fnDown), (Self.talk + 0.5, .escape), (Self.talk + 0.6, .fnUp)]
        let rig = try Self.rig(steps: steps)
        try await rig.engine.start()
        await soon(10, "rig.log.pills.contains { $0.0 == .cancel }") { rig.log.pills.contains { $0.0 == .cancel } }
        let id = try #require(rig.log.pills.first?.1)
        #expect(await rig.engine.paste(id) == .inserted)
        await soon(2, "the text in the target field") { rig.target.field.hasPrefix(FakeSpeech.text(0..<8)) }
        rig.engine.stop()
    }

    @Test func pastingAMissingTakeIsEmpty() async throws {
        let rig = try Self.rig(steps: [])
        try await rig.engine.start()
        #expect(await rig.engine.paste(UUID()) == .empty)
        rig.engine.stop()
    }
}
