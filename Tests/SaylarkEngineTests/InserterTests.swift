import AppKit
import Testing
@testable import SaylarkCore
@testable import SaylarkEngine

/// The Inserter with an in-memory pasteboard, a recording key poster and scripted focus. No real
/// clipboard, keys or accessibility.
@MainActor
@Suite struct InserterTests {
    static let field = FocusInfo(kind: .editableText, engine: .web, pid: 100, caret: .init(before: "", after: ""))
    static let native = FocusInfo(kind: .editableText, engine: .native, pid: 100, caret: .init(before: "", after: ""), canSetSelectedText: true)
    static let nothing = FocusInfo(kind: .notText, engine: .native, pid: 100)
    static let user = PasteboardSnapshot.Item([.init(type: "public.utf8-plain-text", data: Data("USER".utf8)),
                                               .init(type: "public.rtf", data: Data("{\\rtf1 USER}".utf8))])

    static var fast: InsertionMachine.Config {
        var c = InsertionMachine.Config()
        c.quietAfterRead = 0.02
        c.minHoldAfterKey = 0.03
        c.readTimeout = 0.3
        c.holdWhenReadBeforeKey = 0.1
        c.fieldWaitTimeout = 2
        return c
    }

    struct Rig {
        let pb: MemoryPasteboard
        let keys: RecordingKeyPoster
        let probe: ScriptedFocusProbe
        let ax: RecordingAccessibilityInserter
        let inserter: Inserter
    }

    func rig(focus: [FocusInfo] = [field], clipboard: InsertionMachine.ClipboardAccess = .allowed, canPostKeys: Bool = true,
             targetReads: Bool = true, axResult: Bool = true, config: InsertionMachine.Config = fast) -> Rig {
        let pb = MemoryPasteboard(items: [Self.user])
        pb.access = clipboard
        let keys = RecordingKeyPoster()
        if targetReads { keys.onPaste = { _ in pb.readString() } }
        let probe = ScriptedFocusProbe(focus)
        let ax = RecordingAccessibilityInserter(result: axResult)
        let parts = Inserter.Parts(
            pasteboard: pb, keys: keys, focus: probe, watcher: PollingFieldWatcher(probe: probe, interval: 0.01),
            accessibility: ax, environment: { .init(clipboard: pb.access, canPostKeys: canPostKeys) })
        return Rig(pb: pb, keys: keys, probe: probe, ax: ax, inserter: Inserter(parts: parts, config: config))
    }

    func clipboardText(_ pb: MemoryPasteboard) -> String? {
        pb.items.first?.data("public.utf8-plain-text").flatMap { String(data: $0, encoding: .utf8) }
    }

    @Test func pastesThenRestoresTheUsersClipboardIntact() async {
        let r = rig()
        var pastedText: String?
        r.keys.onPaste = { _ in pastedText = r.pb.readString() }
        let result = await r.inserter.insert("hello")
        #expect(result.outcome == .pasted)
        #expect(pastedText == "hello ")
        #expect(r.keys.posts == [100])
        let s = await result.settled.value
        #expect(s.readConfirmed)
        #expect(s.clipboard == .restored)
        #expect(r.pb.items == [Self.user])
        #expect(s.keyMs != nil && s.firstReadMs != nil && s.restoreMs != nil)
        #expect(s.restoreMs! >= s.keyMs! + 30)
    }

    @Test func returnsBeforeTheRestore() async {
        let r = rig()
        let result = await r.inserter.insert("hello")
        // Our text is still up when insert returns; the restore follows.
        #expect(clipboardText(r.pb) == "hello ")
        _ = await result.settled.value
        #expect(clipboardText(r.pb) == "USER")
    }

    @Test func externalCopyDuringThePasteIsNeverClobbered() async {
        let r = rig(targetReads: false)
        r.keys.onPaste = { _ in
            r.pb.readString()
            r.pb.externalWrite("COPIED MEANWHILE")
        }
        let result = await r.inserter.insert("hello")
        let s = await result.settled.value
        #expect(s.clipboard == .leftExternalChange)
        #expect(clipboardText(r.pb) == "COPIED MEANWHILE")
        #expect(r.pb.restores == 0)
    }

    @Test func unreadPasteRestoresAndShowsTheCard() async {
        let r = rig(targetReads: false)
        let result = await r.inserter.insert("hello")
        #expect(result.outcome == .pasted)
        var card: InsertionEvent?
        for await e in r.inserter.events {
            if case .card = e { card = e; break }
        }
        #expect(card == .card(result.id, text: "hello", reason: .pasteNotRead))
        #expect(r.pb.items == [Self.user])
        r.inserter.cardDismiss()
        let s = await result.settled.value
        #expect(s.outcome == .card(.pasteNotRead))
        #expect(s.clipboard == .restored)
    }

    @Test func noFieldCopiesTheTextAndShowsTheCard() async {
        let r = rig(focus: [Self.nothing])
        let result = await r.inserter.insert("hello ", context: .init(copyWhenNoField: true))
        #expect(result.outcome == .noField(.noTextField))
        #expect(result.copiedToClipboard)
        #expect(result.pillOutcome == .noTextFieldCopied("hello"))
        #expect(result.dictationOutcome == .copied)
        #expect(clipboardText(r.pb) == "hello")
        #expect(r.pb.snapshotReads == 0)
        #expect(r.keys.posts.isEmpty)
        r.inserter.cardDismiss()
        #expect(await result.settled.value.clipboard == .copiedForCard)
        #expect(clipboardText(r.pb) == "hello")
    }

    @Test func pasteWhenIClickAFieldAfterTheCopyLeavesTheTextOnTheClipboard() async {
        var later = Self.field
        later.pid = 300
        later.elementID = 7
        let r = rig(focus: [Self.nothing])
        let result = await r.inserter.insert("hello", context: .init(copyWhenNoField: true))
        r.inserter.cardPasteWhenField()
        try? await Task.sleep(for: .milliseconds(50))
        r.probe.set([later])
        let s = await result.settled.value
        #expect(s.viaCard && s.outcome == .pasted)
        #expect(r.keys.posts == [300])
        #expect(clipboardText(r.pb) == "hello", "the paste never brings back an older clipboard")
    }

    @Test func noFieldWithCopyOffShowsTheCardWithoutTouchingTheClipboard() async {
        let r = rig(focus: [Self.nothing])
        let result = await r.inserter.insert("hello", context: .init(copyWhenNoField: false))
        #expect(result.outcome == .noField(.noTextField))
        #expect(result.pillOutcome == .noTextField("hello"))
        #expect(r.pb.changeCount == 0)
        #expect(r.pb.snapshotReads == 0)
        #expect(r.keys.posts.isEmpty)
        r.inserter.cardDismiss()
        #expect(await result.settled.value.clipboard == .untouched)
    }

    @Test func cardCopyIsAnExplicitOverwrite() async {
        let r = rig(focus: [Self.nothing])
        let result = await r.inserter.insert("hello", context: .init(copyWhenNoField: false))
        r.inserter.cardCopy()
        r.inserter.cardDismiss()
        #expect(await result.settled.value.clipboard == .copiedByUser)
        #expect(clipboardText(r.pb) == "hello")
    }

    @Test func pasteWhenIClickAFieldWaitsForAFieldThenPastes() async {
        var later = Self.field
        later.pid = 300
        later.elementID = 7
        later.caret = .init(before: "ok", after: "")
        let r = rig(focus: [Self.nothing])
        let result = await r.inserter.insert("hello", context: .init(copyWhenNoField: false))
        #expect(result.outcome == .noField(.noTextField))
        r.inserter.cardPasteWhenField()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(r.keys.posts.isEmpty)
        r.probe.set([later])
        let s = await result.settled.value
        #expect(s.viaCard)
        #expect(s.outcome == .pasted)
        #expect(s.clipboard == .restored)
        #expect(r.keys.posts == [300])
        #expect(r.pb.items == [Self.user])
    }

    @Test func backToBackTakesRestoreTheUsersClipboardNotTheFirstText() async {
        var config = Self.fast
        config.quietAfterRead = 0.5
        let r = rig(config: config)
        let first = await r.inserter.insert("one")
        let second = await r.inserter.insert("two")
        #expect(await first.settled.value.clipboard == .handedOff)
        let s = await second.settled.value
        #expect(s.clipboard == .restored)
        #expect(r.pb.items == [Self.user])
        #expect(r.pb.snapshotReads == 1)
        #expect(r.keys.posts.count == 2)
    }

    @Test func unreadableClipboardUsesAccessibilityInNativeFields() async {
        let r = rig(focus: [Self.native], clipboard: .wouldPrompt)
        let result = await r.inserter.insert("hello")
        #expect(result.outcome == .insertedViaAccessibility)
        #expect(r.ax.inserted == ["hello "])
        #expect(r.pb.snapshotReads == 0)
        #expect(r.pb.changeCount == 0)
    }

    @Test func unreadableClipboardInWebFieldsShowsTheCard() async {
        let r = rig(clipboard: .wouldPrompt)
        let result = await r.inserter.insert("hello")
        #expect(result.outcome == .failed(.clipboardUnavailable))
        #expect(r.pb.changeCount == 0)
    }

    @Test func keyFailureRestoresAtOnce() async {
        let r = rig()
        r.keys.failure = KeyPostError.targetNotFrontmost(expected: 100, actual: 5)
        let result = await r.inserter.insert("hello")
        #expect(result.outcome == .failed(.cannotPostKeys))
        #expect(r.pb.items == [Self.user])
    }

    @Test func appSwitchShowsTheCard() async {
        var other = Self.field
        other.pid = 200
        let r = rig(focus: [other])
        let result = await r.inserter.insert("hello", context: .init(focusAtStart: Self.field))
        #expect(result.outcome == .failed(.appChanged))
        #expect(r.keys.posts.isEmpty)
    }

    @Test func smartSpacingFollowsTheCaret() async {
        var f = Self.field
        f.caret = .init(before: "rd", after: ".")
        let r = rig(focus: [f])
        var pasted: String?
        r.keys.onPaste = { _ in pasted = r.pb.readString() }
        _ = await r.inserter.insert("next")
        #expect(pasted == " next")
    }

    @Test func emptyTextDoesNothing() async {
        let r = rig()
        let result = await r.inserter.insert("  ")
        #expect(result.outcome == .empty)
        #expect(r.pb.changeCount == 0)
    }

    @Test func aPendingRestoreSurvivesTheInserterGoingAway() async {
        let pb = MemoryPasteboard(items: [Self.user])
        let keys = RecordingKeyPoster { _ in pb.readString() }
        let probe = ScriptedFocusProbe([Self.field])
        var inserter: Inserter? = Inserter(parts: .init(
            pasteboard: pb, keys: keys, focus: probe, watcher: PollingFieldWatcher(probe: probe),
            accessibility: RecordingAccessibilityInserter(), environment: { .init(clipboard: .allowed, canPostKeys: true) }), config: Self.fast)
        let result = await inserter!.insert("hello")
        inserter = nil
        #expect(await result.settled.value.clipboard == .restored)
        #expect(pb.items == [Self.user])
    }

    @Test func flushRestoresAPendingClipboard() async {
        var config = Self.fast
        config.quietAfterRead = 5
        let r = rig(config: config)
        _ = await r.inserter.insert("hello")
        #expect(clipboardText(r.pb) == "hello ")
        await r.inserter.flush()
        #expect(r.pb.items == [Self.user])
    }
}

/// The V key per layout, read from installed layouts without selecting any of them.
@MainActor
@Suite struct KeyboardLayoutTests {
    @Test func findsTheVKeyOnEachLayout() {
        let expected: [(String, CGKeyCode)] = [
            ("com.apple.keylayout.US", 9), ("com.apple.keylayout.Dvorak", 47),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", 9), ("com.apple.keylayout.French", 9),
        ]
        var checked = 0
        for (id, code) in expected {
            guard let k = KeyboardLayout.keyCode(for: "v", layoutID: id) else { continue }
            checked += 1
            #expect(k.code == code, "\(id)")
        }
        #expect(checked > 0)
        #expect(KeyboardLayout.keyCode(for: "v").code < 128)
    }
}
