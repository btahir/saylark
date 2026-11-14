import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SaylarkCore
import SaylarkEngine

/// `saylark insert-test`: drives the whole insertion path end to end inside this process.
///
/// Safety, because the owner is using this Mac while it runs:
/// - The clipboard is a private named pasteboard. `NSPasteboard.general` is never touched: the
///   harness's text views paste from the named board, and the only ⌘V handler is ours.
/// - ⌘V goes to this process only (`SystemKeyPoster(.onlyProcess(getpid()))`), never the HID
///   stream. If it does not arrive, checks fall back to calling the paste handler directly.
/// - The window is borderless and off screen; the app is an accessory and never activates.
/// - The password field is never made first responder: that could turn on Secure Event Input for
///   the whole system while the owner types. Its focus is simulated.
@MainActor
enum InsertTestCommand {
    static func run(_ args: Arguments) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let harness = Harness(verbose: args.flag("verbose"))
        Task { @MainActor in
            let failed = await harness.runAll()
            exit(failed ? 1 : 0)
        }
        app.run()
    }
}

// MARK: - Window and views

/// A text view that pastes only from the harness's named pasteboard.
final class HarnessTextView: NSTextView {
    var board: NSPasteboard?

    func pasteFromBoard() {
        guard let board else { return }
        _ = readSelection(from: board, type: .string)
    }

    override func paste(_ sender: Any?) { pasteFromBoard() }
    override func pasteAsPlainText(_ sender: Any?) { pasteFromBoard() }
    override func pasteAsRichText(_ sender: Any?) { pasteFromBoard() }
}

/// A focusable view that is not text (shows as a list to accessibility).
final class NonTextView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
}

final class HarnessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class Harness: NSObject, NSWindowDelegate {
    let verbose: Bool
    let window: HarnessWindow
    let textView: HarnessTextView
    let textField: NSTextField
    let secureField: NSSecureTextField
    let nonText: NonTextView
    let fieldEditor = HarnessTextView()
    let board = SystemPasteboard.named()
    /// What the harness considers focused (the secure field's focus is simulated).
    var focused: NSView?

    enum PasteMode { case paste, ignore }
    var pasteMode = PasteMode.paste
    /// Runs right after a paste is handled (to simulate another app copying meanwhile).
    var afterPaste: (() -> Void)?
    /// Every ⌘V-looking keyDown that reached this process.
    var received: [(code: UInt16, flags: NSEvent.ModifierFlags, chars: String?, at: Double)] = []
    var unsafePasteAttempts = 0
    var keysDelivered = true
    var expectedKey: CGKeyCode = 9

    var rows: [Row] = []
    struct Row {
        var check: String
        var result: String
        var keyMs: Double?
        var readMs: Double?
        var restoreMs: Double?
        var note: String
    }

    init(verbose: Bool) {
        self.verbose = verbose
        window = HarnessWindow(contentRect: NSRect(x: -4000, y: -4000, width: 480, height: 320),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        textView = HarnessTextView(frame: NSRect(x: 10, y: 180, width: 460, height: 120))
        textField = NSTextField(frame: NSRect(x: 10, y: 140, width: 460, height: 24))
        secureField = NSSecureTextField(frame: NSRect(x: 10, y: 100, width: 460, height: 24))
        nonText = NonTextView(frame: NSRect(x: 10, y: 10, width: 460, height: 80))
        super.init()
        precondition(board.pasteboard.name != .general)
        textView.board = board.pasteboard
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        fieldEditor.board = board.pasteboard
        fieldEditor.isFieldEditor = true
        fieldEditor.isRichText = false
        for v in [textView, textField, secureField, nonText] as [NSView] { window.contentView?.addSubview(v) }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()  // off screen; no activation
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        // Plain text fields edit through our board-only text view; the password field keeps its
        // own secure editor (and is never focused anyway).
        if client is NSSecureTextField { return nil }
        return client is NSTextField ? fieldEditor : nil
    }

    // MARK: Focus

    func focus(_ view: NSView) {
        focused = view
        if view === secureField {
            window.makeFirstResponder(nil)  // simulated: see the type comment
        } else {
            window.makeFirstResponder(view)
        }
    }

    /// The text view that would receive a paste for the focused control.
    var editor: HarnessTextView? {
        if focused === textView { return textView }
        if focused === textField { return window.firstResponder as? HarnessTextView }
        return nil
    }

    func setText(_ text: String, selection: NSRange? = nil) {
        guard let focused else { return }
        if focused === textView {
            textView.string = text
            textView.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
        } else if focused === textField {
            textField.stringValue = text
            window.makeFirstResponder(textField)
            editor?.string = text
            editor?.setSelectedRange(selection ?? NSRange(location: (text as NSString).length, length: 0))
        }
    }

    var currentText: String { editor?.string ?? "" }

    // MARK: ⌘V arriving in this process

    func installMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags.contains(.command) else { return event }
            self.received.append((event.keyCode, flags, event.charactersIgnoringModifiers, HotkeyClock.now))
            if event.charactersIgnoringModifiers?.lowercased() == "v" { self.handlePaste() }
            return nil  // never let AppKit route it anywhere else
        }
    }

    func handlePaste() {
        guard pasteMode == .paste else { return }
        guard let editor, focused !== secureField else {
            if focused === secureField { unsafePasteAttempts += 1 }
            return
        }
        editor.pasteFromBoard()
        afterPaste?()
    }

    // MARK: Parts

    func makeInserter(probe: (any FocusProbe)? = nil, ax: (any AccessibilityInserter)? = nil,
                      clipboard: InsertionMachine.ClipboardAccess? = nil, config: InsertionMachine.Config) -> Inserter {
        let probe = probe ?? AppKitFocusProbe(harness: self)
        let keys = HarnessKeyPoster(harness: self)
        let board = self.board
        return Inserter(parts: .init(
            pasteboard: board, keys: keys, focus: probe, watcher: PollingFieldWatcher(probe: probe, interval: 0.05),
            accessibility: ax ?? AXTextInserter(scope: .application(getpid())),
            environment: { .init(clipboard: clipboard ?? board.access, canPostKeys: true) }), config: config)
    }

    static var config: InsertionMachine.Config {
        var c = InsertionMachine.Config()
        c.readTimeout = 1.0  // shorter than production (3 s) so the run stays quick
        return c
    }

    // MARK: Running

    func runAll() async -> Bool {
        defer { board.release() }
        installMonitor()
        let axTrusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        let secureBefore = IsSecureEventInputEnabled()
        print("saylark insert-test: pid \(getpid()), named pasteboard \(board.pasteboard.name.rawValue)")
        print("accessibility trusted: \(axTrusted); post-event access: \(postAccess); secure input on: \(secureBefore)")
        print("named board accessBehavior raw \(board.pasteboard.accessBehavior.rawValue) -> \(board.access)")
        window.makeKey()
        print("window key: \(window.isKeyWindow); app active: \(NSApp.isActive); NSApp.keyWindow set: \(NSApp.keyWindow != nil)")

        await checkKeyDelivery()
        checkLayouts()
        await checkLanding()
        await checkRestores()
        await checkExternalChange()
        await checkCards()
        await checkWaitForField()
        await checkPasteNotRead()
        await checkBackToBack()
        await checkAccessibility(trusted: axTrusted)
        checkReceiptCache()
        if IsSecureEventInputEnabled() != secureBefore { add("secure-input-untouched", "FAIL", note: "Secure Event Input changed during the run") }
        if unsafePasteAttempts > 0 { add("no-paste-into-secure", "FAIL", note: "\(unsafePasteAttempts) paste(s) aimed at the password field") }

        print("paste delivery: \(keysDelivered ? "⌘V events posted to this process" : "paste handler called directly (posted ⌘V did not arrive)")")
        printTable()
        return rows.contains { $0.result == "FAIL" }
    }

    func add(_ check: String, _ result: String, key: Double? = nil, read: Double? = nil, restore: Double? = nil, note: String = "") {
        rows.append(Row(check: check, result: result, keyMs: key, readMs: read, restoreMs: restore, note: note))
        if verbose { print("  \(result) \(check) \(note)") }
    }

    func add(_ check: String, _ ok: Bool, _ s: InsertionMachine.Settlement?, note: String) {
        add(check, ok ? "PASS" : "FAIL", key: s?.keyMs, read: s?.firstReadMs, restore: s?.restoreMs, note: note)
    }

    func printTable() {
        func ms(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
        let w = max(24, rows.map(\.check.count).max() ?? 0)
        let header = "check".padding(toLength: w, withPad: " ", startingAt: 0) + "  result  key ms  read ms  restore ms  note"
        print("")
        print(header)
        print(String(repeating: "-", count: header.count + 20))
        for r in rows {
            let line = r.check.padding(toLength: w, withPad: " ", startingAt: 0) + "  "
                + r.result.padding(toLength: 6, withPad: " ", startingAt: 0) + "  "
                + ms(r.keyMs).leftPad(6) + "  " + ms(r.readMs).leftPad(7) + "  " + ms(r.restoreMs).leftPad(10) + "  " + r.note
            print(line)
        }
        let pass = rows.filter { $0.result == "PASS" }.count, fail = rows.filter { $0.result == "FAIL" }.count
        let skip = rows.filter { $0.result == "SKIP" }.count
        print("\n\(pass) passed, \(fail) failed, \(skip) skipped")
    }

    // MARK: Checks

    func checkKeyDelivery() async {
        focus(textView)
        setText("")
        pasteMode = .ignore
        received = []
        let poster = SystemKeyPoster(delivery: .onlyProcess(getpid()))
        let start = HotkeyClock.now
        do { try await poster.postPaste(targetPID: nil) } catch {
            add("key-delivery", "FAIL", note: "post failed: \(error)")
            keysDelivered = false
            pasteMode = .paste
            return
        }
        expectedKey = poster.lastKey?.code ?? 9
        let got = await waitFor(0.5) { !self.received.isEmpty }
        pasteMode = .paste
        guard got, let e = received.first else {
            keysDelivered = false
            add("key-delivery", "SKIP", note: "⌘V posted to own pid did not arrive (PostEvent access \(CGPreflightPostEventAccess()), app active \(NSApp.isActive)); later checks call the paste handler directly")
            return
        }
        let ok = e.flags == .command && e.code == UInt16(expectedKey) && e.chars?.lowercased() == "v"
        add("key-delivery", ok ? "PASS" : "FAIL", key: (e.at - start) * 1000,
            note: "keycode \(e.code) via \(poster.lastKey?.how ?? "?") (\(poster.lastKey?.layoutID ?? "?")), flags \(ok ? "exactly ⌘" : "\(e.flags.rawValue)")")
    }

    func checkLayouts() {
        var notes: [String] = []
        var ok = true
        let expect: [(String, CGKeyCode)] = [
            ("com.apple.keylayout.US", 9), ("com.apple.keylayout.Dvorak", 47),
            ("com.apple.keylayout.DVORAK-QWERTYCMD", 9), ("com.apple.keylayout.French", 9),
            ("com.apple.keylayout.Colemak", 9),
        ]
        var seen = 0
        for (id, code) in expect {
            guard let k = KeyboardLayout.keyCode(for: "v", layoutID: id) else { continue }
            seen += 1
            notes.append("\(id.replacingOccurrences(of: "com.apple.keylayout.", with: ""))=\(k.code)/\(k.how)")
            if k.code != code { ok = false }
        }
        add("layout-v-key", seen == 0 ? "SKIP" : (ok ? "PASS" : "FAIL"), note: notes.joined(separator: " "))
    }

    /// One paste into `view` with `text` and `selection`; checks the result text.
    func land(_ name: String, view: NSView, text: String, selection: NSRange? = nil, dictate: String, expect: String) async {
        writeFixture { $0.setString("fixture", forType: .string) }
        let fixture = try? board.snapshot()
        focus(view)
        setText(text, selection: selection)
        let inserter = makeInserter(config: Self.config)
        let result = await inserter.insert(dictate)
        let s = await settle(result)
        let got = currentText
        let restored = (try? board.snapshot()).map { fixture?.sameContent(as: $0) == true } ?? false
        let ok = result.outcome == .pasted && got == expect && restored && s?.clipboard == .restored
        add(name, ok, s, note: ok ? "\(show(text)) + \(show(dictate)) -> \(show(got))"
            : "outcome \(result.outcome), got \(show(got)) want \(show(expect)), restored \(restored), \(s.map { "\($0.clipboard)" } ?? "no settlement")")
    }

    func checkLanding() async {
        await land("textview-at-caret", view: textView, text: "Hello world", selection: NSRange(location: 5, length: 0),
                   dictate: "there", expect: "Hello there world")
        await land("textview-replace-selection", view: textView, text: "one two three", selection: NSRange(location: 4, length: 3),
                   dictate: "2", expect: "one 2 three")
        await land("textfield-empty", view: textField, text: "", dictate: "Hello", expect: "Hello ")
        await land("textfield-continue", view: textField, text: "Hi", dictate: "there.", expect: "Hi there. ")
        await land("spacing-after-bracket", view: textView, text: "call (", dictate: "now", expect: "call (now ")
        await land("spacing-no-double", view: textView, text: "Done. ", dictate: "Next", expect: "Done. Next ")
        await land("spacing-newline", view: textView, text: "List:\n", dictate: "item", expect: "List:\nitem ")
    }

    func writeFixture(_ write: (NSPasteboard) -> Void) {
        board.pasteboard.clearContents()
        write(board.pasteboard)
    }

    final class LazyFixture: NSObject, NSPasteboardItemDataProvider {
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString("lazily provided", forType: type)
        }
    }

    func checkRestores() async {
        let rtf = (try? NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            .data(from: NSRange(location: 0, length: 4), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
        let png = Self.png()
        let fileURL = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        let lazy = LazyFixture()
        let fixtures: [(String, (NSPasteboard) -> Void)] = [
            ("restore-text", { $0.setString("my clipboard text", forType: .string) }),
            ("restore-rtf", { pb in pb.declareTypes([.rtf, .string], owner: nil); pb.setData(rtf, forType: .rtf); pb.setString("bold", forType: .string) }),
            ("restore-image", { $0.setData(png, forType: .png) }),
            ("restore-file-url", { $0.writeObjects([fileURL as NSURL]) }),
            ("restore-multi-item", { $0.writeObjects(["first" as NSString, "second" as NSString, URL(string: "https://example.com")! as NSURL]) }),
            ("restore-lazy-type", { pb in let item = NSPasteboardItem(); item.setDataProvider(lazy, forTypes: [.string]); pb.writeObjects([item]) }),
            ("restore-empty", { _ in }),
        ]
        for (name, write) in fixtures {
            writeFixture(write)
            guard let fixture = try? board.snapshot() else { add(name, "FAIL", note: "fixture snapshot failed"); continue }
            focus(textView)
            setText("x")
            let result = await makeInserter(config: Self.config).insert("pasted")
            let s = await settle(result)
            let after = try? board.snapshot()
            let intact = after.map { fixture.sameContent(as: $0) } ?? false
            let landed = currentText == "x pasted "
            let types = fixture.items.map { $0.types.count }
            add(name, intact && landed && s?.clipboard == .restored, s,
                note: "\(fixture.items.count) item(s), types \(types), \(fixture.byteCount) B; intact \(intact), landed \(landed)")
        }
    }

    func checkExternalChange() async {
        writeFixture { $0.setString("old user clip", forType: .string) }
        focus(textView)
        setText("")
        afterPaste = { [board] in
            // Another app copies right after the target read ours, before our restore.
            board.pasteboard.clearContents()
            board.pasteboard.setString("copied meanwhile", forType: .string)
        }
        let result = await makeInserter(config: Self.config).insert("hello")
        let s = await settle(result)
        afterPaste = nil
        let now = board.pasteboard.string(forType: .string)
        let ok = now == "copied meanwhile" && s?.clipboard == .leftExternalChange && currentText == "hello "
        add("external-change-kept", ok, s, note: "clipboard after: \(show(now ?? "nil")), \(s.map { "\($0.clipboard)" } ?? "-")")
    }

    func checkCards() async {
        for (name, view, reason) in [("secure-field-card", secureField as NSView, InsertionMachine.CardReason.secureField),
                                     ("no-field-card", nonText as NSView, .noTextField)] {
            writeFixture { $0.setString("untouched", forType: .string) }
            let count = board.changeCount
            received = []
            focus(view)
            let inserter = makeInserter(config: Self.config)
            let result = await inserter.insert("secret words")
            inserter.cardDismiss()
            let s = await settle(result)
            // No text field: the text is copied for the user and stays. Never next to a password field.
            let copies = reason == .noTextField
            let clipboardOK = copies
                ? board.pasteboard.string(forType: .string) == "secret words" && s?.clipboard == .copiedForCard && result.copiedToClipboard
                : board.changeCount == count && s?.clipboard == .untouched && !result.copiedToClipboard
            let ok = result.outcome == .noField(reason) && received.isEmpty && clipboardOK && result.cardText == "secret words"
            let state = board.changeCount == count ? "untouched" : "now \(show(board.pasteboard.string(forType: .string) ?? "nil"))"
            add(name, ok, s, note: "outcome \(describe(result.outcome)); clipboard \(state); keys \(received.count)")
        }
    }

    func checkWaitForField() async {
        writeFixture { $0.setString("keep me", forType: .string) }
        focus(textView)
        setText("Note:")
        focus(nonText)
        let inserter = makeInserter(config: Self.config)
        let called = HotkeyClock.now
        let result = await inserter.insert("from the card")
        guard result.outcome == .noField(.noTextField) else {
            add("wait-for-field", "FAIL", note: "expected the card, got \(result.outcome)")
            return
        }
        inserter.cardPasteWhenField()
        try? await Task.sleep(for: .milliseconds(300))
        let early = currentText
        let clicked = HotkeyClock.now
        focus(textView)  // the user clicks into a field
        let s = await settle(result, timeout: 5)
        // ⌘V time relative to the focus change (not the settle, which includes the restore wait).
        let landedMs = s?.keyMs.map { $0 - (clicked - called) * 1000 }
        // The card copied the text; the paste's restore puts that back, never the older "keep me".
        let restored = board.pasteboard.string(forType: .string) == "from the card"
        let ok = early == "" && currentText == "Note: from the card " && s?.viaCard == true && s?.outcome == .pasted && restored
        add("wait-for-field", ok, s, note: "landed \(landedMs.map { String(format: "%.0f ms", $0) } ?? "never") after focus moved; text \(show(currentText)); copied text kept \(restored)")
    }

    func checkPasteNotRead() async {
        writeFixture { $0.setString("still mine", forType: .string) }
        let fixture = try? board.snapshot()
        focus(textView)
        setText("")
        pasteMode = .ignore  // the target swallows ⌘V without reading
        let inserter = makeInserter(config: Self.config)
        var card = false
        let watch = Task { @MainActor in
            for await e in inserter.events { if case .card(_, _, .pasteNotRead) = e { card = true; inserter.cardDismiss(); return } }
        }
        let result = await inserter.insert("lost?")
        let s = await settle(result, timeout: 4)
        watch.cancel()
        pasteMode = .paste
        let restored = (try? board.snapshot()).map { fixture?.sameContent(as: $0) == true } ?? false
        let ok = card && s?.outcome == .card(.pasteNotRead) && restored && currentText == ""
        add("paste-not-read-card", ok, s, note: "card \(card), restored \(restored) (read timeout \(Self.config.readTimeout) s)")
    }

    func checkBackToBack() async {
        writeFixture { $0.setString("original", forType: .string) }
        let fixture = try? board.snapshot()
        focus(textView)
        setText("")
        let inserter = makeInserter(config: Self.config)
        let first = await inserter.insert("One.")
        let second = await inserter.insert("Two.")
        let s1 = await settle(first), s2 = await settle(second)
        let restored = (try? board.snapshot()).map { fixture?.sameContent(as: $0) == true } ?? false
        let ok = currentText == "One. Two. " && restored && s1?.clipboard == .handedOff && s2?.clipboard == .restored
        add("back-to-back", ok, s2, note: "text \(show(currentText)); first \(s1.map { "\($0.clipboard)" } ?? "-"), second \(s2.map { "\($0.clipboard)" } ?? "-")")
    }

    func checkAccessibility(trusted: Bool) async {
        guard trusted else {
            for name in ["ax-probe-textview", "ax-probe-nontext", "ax-insert-native"] {
                add(name, "SKIP", note: "Accessibility is not granted to this process (AXIsProcessTrusted false)")
            }
            add("ax-probe-secure", "SKIP", note: "never focus a real password field: it can turn on Secure Event Input system-wide")
            return
        }
        // This CLI has no app bundle, so the probe can't tell its UI engine; it is AppKit.
        let probe = NativeEngineProbe(base: AXFocusProbe(scope: .application(getpid()), timeout: 0.5))
        focus(textView)
        setText("Hello world", selection: NSRange(location: 5, length: 0))
        let f = await probe.focused()
        let okText = f.kind == .editableText && f.caret.before == "lo" && f.caret.after == " " && f.engine == .native
        add("ax-probe-textview", okText ? "PASS" : (f.kind == .unknown || f.role == nil ? "SKIP" : "FAIL"),
            note: "kind \(f.kind), role \(f.role ?? "-"), caret \(show(f.caret.before ?? "nil"))|\(show(f.caret.after ?? "nil")), \(String(format: "%.1f", f.probeMs)) ms \(f.note ?? "")")
        focus(nonText)
        let n = await probe.focused()
        add("ax-probe-nontext", n.kind == .notText ? "PASS" : (n.role == nil ? "SKIP" : "FAIL"), note: "kind \(n.kind), role \(n.role ?? "-") \(n.note ?? "")")
        add("ax-probe-secure", "SKIP", note: "never focus a real password field: it can turn on Secure Event Input system-wide")

        writeFixture { $0.setString("not touched", forType: .string) }
        let count = board.changeCount
        focus(textView)
        setText("Hello", selection: NSRange(location: 5, length: 0))
        let inserter = makeInserter(probe: probe, ax: AXTextInserter(scope: .application(getpid())), clipboard: .wouldPrompt, config: Self.config)
        let result = await inserter.insert("again")
        let s = await settle(result)
        let ok = result.outcome == .insertedViaAccessibility && currentText == "Hello again " && board.changeCount == count
        add("ax-insert-native", ok ? "PASS" : (f.kind == .editableText ? "FAIL" : "SKIP"), key: s?.keyMs,
            note: "outcome \(result.outcome), text \(show(currentText)), clipboard \(board.changeCount == count ? "untouched" : "CHANGED")")
    }

    /// Does a second read of our promise call the provider again? In process only; across
    /// processes the pasteboard server may cache.
    func checkReceiptCache() {
        var reads = 0
        _ = board.writeTransient("probe") { reads += 1 }
        _ = board.pasteboard.string(forType: .string)
        _ = board.pasteboard.string(forType: .string)
        add("receipt-count-2-reads", "INFO", note: "provider called \(reads)x for 2 reads (same process)")
        board.pasteboard.clearContents()
    }

    // MARK: Helpers

    func settle(_ result: InsertionResult, timeout: Double = 3) async -> InsertionMachine.Settlement? {
        let task = result.settled
        let deadline = HotkeyClock.now + timeout
        var value: InsertionMachine.Settlement?
        let waiter = Task { @MainActor in value = await task.value }
        while value == nil, HotkeyClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        waiter.cancel()
        return value
    }

    func waitFor(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let end = HotkeyClock.now + seconds
        while !condition() {
            if HotkeyClock.now > end { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    func describe(_ o: InsertionOutcome) -> String {
        switch o {
        case .pasted: "pasted"
        case .insertedViaAccessibility: "accessibility"
        case .noField(let r): "card (\(r.rawValue))"
        case .failed(let r): "failed, card (\(r.rawValue))"
        case .empty: "empty"
        }
    }

    func show(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\n", with: "\\n") + "\"" }

    static func png() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.setColor(NSColor(deviceRed: 0, green: 0.4, blue: 1, alpha: 1), atX: 2, y: 3)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// ⌘V to this process only. When posted events don't arrive (an inactive app may not get them),
/// it calls the paste handler directly, on the next main-loop turn like a real target would.
@MainActor
final class HarnessKeyPoster: KeyPoster {
    unowned let harness: Harness
    let real = SystemKeyPoster(delivery: .onlyProcess(getpid()))

    init(harness: Harness) { self.harness = harness }

    func postPaste(targetPID: Int32?) async throws {
        if harness.keysDelivered {
            try await real.postPaste(targetPID: nil)
        } else {
            DispatchQueue.main.async { [harness] in MainActor.assumeIsolated { harness.handlePaste() } }
        }
    }

    func postReturn(targetPID: Int32?) async throws {
        if harness.keysDelivered { try await real.postReturn(targetPID: nil) }
    }
}

/// Marks answers from this (bundle-less, AppKit) process as native.
struct NativeEngineProbe: FocusProbe {
    let base: AXFocusProbe
    func focused() async -> FocusInfo {
        var f = await base.focused()
        if f.engine == .unknown { f.engine = .native }
        return f
    }
}

/// Focus as AppKit sees it inside this process, for when the accessibility probe can't be used.
final class AppKitFocusProbe: FocusProbe, @unchecked Sendable {
    unowned let harness: Harness

    init(harness: Harness) { self.harness = harness }

    func focused() async -> FocusInfo {
        await MainActor.run {
            let h = harness
            let pid = getpid()
            guard let view = h.focused else { return FocusInfo(kind: .notText, engine: .native, pid: pid) }
            if view === h.secureField {
                return FocusInfo(kind: .secureText, engine: .native, pid: pid, role: "AXTextField", subrole: "AXSecureTextField",
                                 elementID: UInt(bitPattern: ObjectIdentifier(view).hashValue))
            }
            guard let editor = h.editor else {
                let kind = FocusClassifier.kind(hasFocusedElement: true, role: "AXList", subrole: nil, editable: nil,
                                                valueSettable: false, selectedTextSettable: false, engine: .native)
                return FocusInfo(kind: kind, engine: .native, pid: pid, role: "AXList",
                                 elementID: UInt(bitPattern: ObjectIdentifier(view).hashValue))
            }
            let range = editor.selectedRange()
            let s = editor.string as NSString
            let start = range.location, end = range.location + range.length
            let before = start == 0 ? "" : s.substring(with: NSRange(location: max(0, start - 2), length: min(2, start)))
            let after = end >= s.length ? "" : s.substring(with: NSRange(location: end, length: 1))
            return FocusInfo(kind: .editableText, engine: .native, pid: pid, role: view === h.textView ? "AXTextArea" : "AXTextField",
                             elementID: UInt(bitPattern: ObjectIdentifier(view).hashValue), selectionLocation: start,
                             selectionLength: range.length, caret: .init(before: before, after: after), canSetSelectedText: true)
        }
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
