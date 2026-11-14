import Testing
@testable import SaylarkCore

/// Timelines through the insertion machine. The driver ticks the machine at its deadline before
/// each input, as the Inserter's timer would.
@Suite struct InsertionMachineTests {
    typealias M = InsertionMachine
    typealias I = InsertionMachine.Input
    typealias A = InsertionMachine.Action

    static let field = FocusInfo(kind: .editableText, engine: .web, pid: 100, caret: .init(before: "", after: ""))
    static let native = FocusInfo(kind: .editableText, engine: .native, pid: 100, caret: .init(before: "", after: ""), canSetSelectedText: true)
    static let ok = M.Environment(clipboard: .allowed, canPostKeys: true)

    static func begin(_ text: String = "hello", start: FocusInfo? = field, now: FocusInfo = field, env: M.Environment = ok,
                      carried: Bool = false, at t: Double = 0) -> I {
        .begin(text: text, start: start, now: now, env: env, carriedSnapshot: carried, time: t)
    }

    static func time(of input: I) -> Double {
        switch input {
        case .begin(_, _, _, _, _, let t), .snapshotTaken(_, let t), .wrote(_, let t), .keyPosted(let t), .keyFailed(let t),
             .clipboardRead(let t), .changeCount(_, let t), .restored(_, let t), .accessibilityInserted(_, let t),
             .cardCopy(let t), .cardPasteWhenField(let t), .cardDismissed(let t), .fieldFocused(_, let t),
             .supersede(let t), .tick(let t):
            t
        }
    }

    /// Runs inputs in order, firing deadlines before each and finally up to `end`.
    /// Auto-copy on (the setting's off default is tested on its own).
    static let autoCopy: M.Config = { var c = M.Config(); c.copyWhenNoField = true; return c }()

    func run(_ inputs: [I], until end: Double = 60, config: M.Config = Self.autoCopy) -> (machine: M, out: [(Double, A)]) {
        var m = M(config: config)
        var out: [(Double, A)] = []
        func fire(before t: Double) {
            while let d = m.deadline, d <= t {
                out += m.handle(.tick(time: d)).map { (d, $0) }
            }
        }
        for input in inputs {
            let t = Self.time(of: input)
            fire(before: t)
            out += m.handle(input).map { (t, $0) }
        }
        fire(before: end)
        return (m, out)
    }

    func actions(_ inputs: [I], config: M.Config = Self.autoCopy) -> [A] { run(inputs, config: config).out.map(\.1) }

    func settlement(_ actions: [A]) -> M.Settlement? {
        for a in actions { if case .settled(let s) = a { return s } }
        return nil
    }

    /// The standard paste up to ⌘V: snapshot, write (change count 7), key at 0.01.
    static let pasteToKey: [I] = [begin(), .snapshotTaken(ok: true, time: 0.001), .wrote(changeCount: 7, time: 0.002), .keyPosted(time: 0.01)]

    // MARK: The happy path

    @Test func pasteSnapshotsWritesPostsAndRestoresAfterTheRead() {
        let r = run(Self.pasteToKey + [.clipboardRead(time: 0.05), .restored(ok: true, time: 0.31)])
        let a = r.out.map(\.1)
        #expect(Array(a.prefix(4)) == [.snapshotClipboard, .writeTransient("hello "), .postPaste(pid: 100), .dispatched(.pasted)])
        #expect(a[4] == .restoreClipboard)
        // Restore no sooner than 0.3 s after the key (min hold), even though the read was at 0.05.
        #expect(abs(r.out[4].0 - 0.31) < 1e-9)
        let s = settlement(a)
        #expect(s?.outcome == .pasted)
        #expect(s?.readConfirmed == true)
        #expect(s?.clipboard == .restored)
        #expect(r.machine.isDone)
    }

    @Test func restoreWaitsForTheQuietPeriodAfterTheLastRead() {
        let r = run(Self.pasteToKey + [.clipboardRead(time: 0.2), .clipboardRead(time: 0.35)])
        let restoreAt = r.out.first { $0.1 == .restoreClipboard }?.0
        #expect(restoreAt.map { abs($0 - 0.55) < 1e-9 } == true)  // 0.35 + 0.2
    }

    @Test func aReadWhileTheKeysGoOutIsTheReceipt() {
        let inputs: [I] = [Self.begin(), .snapshotTaken(ok: true, time: 0), .wrote(changeCount: 7, time: 0.001),
                           .clipboardRead(time: 0.005), .keyPosted(time: 0.015), .restored(ok: true, time: 0.315)]
        let r = run(inputs)
        #expect(abs(r.out.first { $0.1 == .restoreClipboard }!.0 - 0.315) < 1e-9)
        let s = settlement(r.out.map(\.1))
        #expect(s?.readConfirmed == true)
        #expect(!r.out.contains { if case .showCard = $0.1 { true } else { false } })
    }

    @Test func dispatchedComesAtTheKeyNotAtTheRestore() {
        let r = run(Self.pasteToKey)
        let dispatched = r.out.first { if case .dispatched = $0.1 { true } else { false } }
        #expect(dispatched?.0 == 0.01)
    }

    @Test func spacingUsesTheCaretContext() {
        var f = Self.field
        f.caret = .init(before: "rd", after: nil)
        #expect(actions([Self.begin("next", now: f), .snapshotTaken(ok: true, time: 0)]).contains(.writeTransient(" next ")))
    }

    // MARK: Someone else changes the clipboard

    @Test func externalChangeBeforeTheReadIsNeverClobbered() {
        let a = actions(Self.pasteToKey + [.changeCount(8, time: 0.1), .clipboardRead(time: 0.2)])
        #expect(!a.contains(.restoreClipboard))
        #expect(a.contains(.dropSnapshot))
        #expect(settlement(a)?.clipboard == .leftExternalChange)
    }

    @Test func externalChangeDuringTheQuietPeriodIsNeverClobbered() {
        let a = actions(Self.pasteToKey + [.clipboardRead(time: 0.05), .changeCount(8, time: 0.2)])
        #expect(!a.contains(.restoreClipboard))
        #expect(settlement(a)?.clipboard == .leftExternalChange)
    }

    @Test func ourOwnChangeCountIsNotAnExternalChange() {
        let a = actions(Self.pasteToKey + [.changeCount(7, time: 0.1), .clipboardRead(time: 0.15)])
        #expect(a.contains(.restoreClipboard))
    }

    @Test func restoreGuardRefusalIsRecorded() {
        let a = actions(Self.pasteToKey + [.clipboardRead(time: 0.05), .restored(ok: false, time: 0.31)])
        #expect(settlement(a)?.clipboard == .leftExternalChange)
    }

    // MARK: Never read

    @Test func noReadRestoresThenShowsTheCard() {
        let r = run(Self.pasteToKey + [.restored(ok: true, time: 3.01)])
        let a = r.out.map(\.1)
        #expect(a.suffix(3) == [.restoreClipboard, .showCard("hello", .pasteNotRead), .dispatched(.card(.pasteNotRead))])
        #expect(abs(r.out.first { $0.1 == .restoreClipboard }!.0 - 3.01) < 1e-9)
        #expect(r.machine.phase == .card(.pasteNotRead))
    }

    @Test func readOnlyBeforeTheKeyRestoresAfterTheHoldWithoutACard() {
        // Writing phase: the read lands between our write and the first key event.
        let inputs: [I] = [Self.begin(), .snapshotTaken(ok: true, time: 0), .clipboardRead(time: 0.001),
                           .wrote(changeCount: 7, time: 0.002), .keyPosted(time: 0.01), .restored(ok: true, time: 1.01)]
        let r = run(inputs)
        let a = r.out.map(\.1)
        #expect(!a.contains { if case .showCard = $0 { true } else { false } })
        #expect(abs(r.out.first { $0.1 == .restoreClipboard }!.0 - 1.01) < 1e-9)
        #expect(settlement(a)?.readConfirmed == false)
        #expect(settlement(a)?.outcome == .pasted)
    }

    // MARK: The card

    @Test func noTextFieldCopiesTheTextAndLeavesIt() {
        var f = Self.field
        f.kind = .notText
        let r = run([Self.begin(now: f), .cardDismissed(time: 2)])
        #expect(r.machine.copiedForCard)
        #expect(r.out.map(\.1) == [.copyToClipboard("hello"), .showCard("hello", .noTextField), .dispatched(.card(.noTextField)),
                                   .settled(.init(outcome: .card(.noTextField), readConfirmed: false, clipboard: .copiedForCard, viaCard: false))])
    }

    @Test func noTextFieldWithCopyOffNeverTouchesTheClipboard() {
        var f = Self.field
        f.kind = .notText
        var config = M.Config()
        config.copyWhenNoField = false
        let a = actions([Self.begin(now: f), .cardDismissed(time: 2)], config: config)
        #expect(a == [.showCard("hello", .noTextField), .dispatched(.card(.noTextField)),
                      .settled(.init(outcome: .card(.noTextField), readConfirmed: false, clipboard: .untouched, viaCard: false))])
    }

    @Test func appSwitchCopiesButPasswordFieldsAndPermissionCardsDoNot() {
        var other = Self.field
        other.pid = 200
        #expect(actions([Self.begin(start: Self.field, now: other)]).first == .copyToClipboard("hello"))
        var secure = Self.field
        secure.kind = .secureText
        #expect(!actions([Self.begin(now: secure)]).contains(.copyToClipboard("hello")), "dictated text by a password field stays off the clipboard")
        let noKeys = M.Environment(clipboard: .allowed, canPostKeys: false)
        #expect(!actions([Self.begin(env: noKeys)]).contains(.copyToClipboard("hello")))
        let blocked = M.Environment(clipboard: .denied, canPostKeys: true)
        #expect(!actions([Self.begin(env: blocked)]).contains(.copyToClipboard("hello")))
    }

    @Test func carriedSnapshotGoesBackBeforeTheCopyAndTheCopyIsWhatStays() {
        var f = Self.field
        f.kind = .notText
        let r = run([Self.begin(now: f, carried: true), .restored(ok: true, time: 0.01), .cardDismissed(time: 2)])
        let a = r.out.map(\.1)
        #expect(Array(a.prefix(2)) == [.restoreClipboard, .copyToClipboard("hello")], "the user's old clipboard never lands over the text")
        #expect(settlement(a)?.clipboard == .copiedForCard)
    }

    @Test func pasteLaterAfterTheCopyPutsTheCopiedTextBack() {
        var none = Self.field
        none.kind = .notText
        var later = Self.field
        later.pid = 300
        let r = run([Self.begin(now: none), .cardPasteWhenField(time: 1), .fieldFocused(later, time: 4),
                     .snapshotTaken(ok: true, time: 4), .wrote(changeCount: 9, time: 4), .keyPosted(time: 4.01),
                     .clipboardRead(time: 4.05), .restored(ok: true, time: 4.31)])
        let a = r.out.map(\.1)
        // The snapshot is taken after the copy, so the restore puts the dictated text back.
        let copy = a.firstIndex(of: .copyToClipboard("hello"))!, snap = a.firstIndex(of: .snapshotClipboard)!
        #expect(copy < snap)
        #expect(a.contains(.restoreClipboard))
        #expect(settlement(a)?.clipboard == .restored)
        #expect(settlement(a)?.viaCard == true)
    }

    @Test func pasteLaterAfterTheCopyWorksWithoutClipboardAccess() {
        var none = Self.field
        none.kind = .notText
        let env = M.Environment(clipboard: .wouldPrompt, canPostKeys: true)
        let r = run([Self.begin(now: none, env: env), .cardPasteWhenField(time: 1), .fieldFocused(Self.field, time: 4),
                     .wrote(changeCount: 9, time: 4), .keyPosted(time: 4.01), .clipboardRead(time: 4.05)])
        let a = r.out.map(\.1)
        #expect(!a.contains(.snapshotClipboard))
        #expect(!a.contains(.restoreClipboard))
        #expect(a.contains(.postPaste(pid: 100)))
        #expect(settlement(a)?.clipboard == .copiedForCard, "the copied text simply stays")
    }

    @Test func secureFieldShowsTheCard() {
        var f = Self.field
        f.kind = .secureText
        let a = actions([Self.begin(now: f)])
        #expect(a.first == .showCard("hello", .secureField))
        #expect(!a.contains { if case .postPaste = $0 { true } else { false } })
    }

    @Test func appSwitchShowsTheCard() {
        var other = Self.field
        other.pid = 200
        #expect(actions([Self.begin(start: Self.field, now: other)]).contains(.showCard("hello", .appChanged)))
        var config = M.Config()
        config.allowAcrossAppSwitch = true
        #expect(actions([Self.begin(start: Self.field, now: other)], config: config).first == .snapshotClipboard)
    }

    @Test func unknownFocusStillPastes() {
        #expect(actions([Self.begin(now: .unknown(pid: 100))]).first == .snapshotClipboard)
        #expect(actions([Self.begin(start: nil, now: .unknown())]).first == .snapshotClipboard)
    }

    @Test func copyIsAnExplicitWrite() {
        var f = Self.field
        f.kind = .notText
        let a = actions([Self.begin(now: f), .cardCopy(time: 1), .cardDismissed(time: 2)])
        #expect(a.contains(.copyToClipboard("hello")))
        #expect(settlement(a)?.clipboard == .copiedByUser)
    }

    @Test func pasteWhenIClickAFieldGoesThroughTheNormalPastePath() {
        var none = Self.field
        none.kind = .notText
        var later = Self.field
        later.pid = 300
        later.caret = .init(before: "hi", after: "")
        let r = run([Self.begin(now: none), .cardPasteWhenField(time: 1), .fieldFocused(later, time: 4),
                     .snapshotTaken(ok: true, time: 4), .wrote(changeCount: 9, time: 4), .keyPosted(time: 4.01),
                     .clipboardRead(time: 4.05), .restored(ok: true, time: 4.31)])
        let a = r.out.map(\.1)
        #expect(a.contains(.armFieldWatch(until: 21)))
        #expect(a.contains(.disarmFieldWatch))
        #expect(a.contains(.writeTransient(" hello ")))
        #expect(a.contains(.postPaste(pid: 300)))
        let s = settlement(a)
        #expect(s?.viaCard == true)
        #expect(s?.outcome == .pasted)
        #expect(s?.clipboard == .restored)
    }

    @Test func fieldWaitIgnoresNonFieldsAndTimesOut() {
        var none = Self.field
        none.kind = .notText
        var secure = Self.field
        secure.kind = .secureText
        let r = run([Self.begin(now: none), .cardPasteWhenField(time: 1), .fieldFocused(none, time: 2), .fieldFocused(secure, time: 3)])
        let a = r.out.map(\.1)
        #expect(!a.contains(.snapshotClipboard))
        #expect(a.suffix(2).first == .disarmFieldWatch)
        #expect(r.out.last?.0 == 21)
        #expect(r.machine.isDone)
    }

    // MARK: Privacy, permissions and the accessibility fallback

    @Test func unreadableClipboardUsesAccessibilityInNativeFields() {
        let env = M.Environment(clipboard: .wouldPrompt, canPostKeys: true)
        let a = actions([Self.begin(now: Self.native, env: env), .accessibilityInserted(ok: true, time: 0.02)])
        #expect(a.first == .insertViaAccessibility("hello ", Self.native))
        #expect(!a.contains(.snapshotClipboard))
        #expect(!a.contains { if case .writeTransient = $0 { true } else { false } })
        #expect(settlement(a)?.outcome == .insertedViaAccessibility)
        #expect(settlement(a)?.clipboard == .untouched)
    }

    @Test func unreadableClipboardInElectronShowsTheCardByDefault() {
        let env = M.Environment(clipboard: .wouldPrompt, canPostKeys: true)
        #expect(actions([Self.begin(env: env)]).first == .showCard("hello", .clipboardUnavailable))
        var config = M.Config()
        config.unreadableClipboard = .pasteWithoutRestore
        let a = actions([Self.begin(env: env), .wrote(changeCount: 3, time: 0), .keyPosted(time: 0.01), .clipboardRead(time: 0.02)], config: config)
        #expect(a.first == .writeTransient("hello "))
        #expect(!a.contains(.restoreClipboard))
        #expect(settlement(a)?.clipboard == .notRestorable)
    }

    @Test func failedSnapshotNeverWrites() {
        let a = actions([Self.begin(), .snapshotTaken(ok: false, time: 0)])
        #expect(!a.contains { if case .writeTransient = $0 { true } else { false } })
        #expect(a.contains(.showCard("hello", .clipboardUnavailable)))
    }

    @Test func keyFailureRestoresAtOnceThenFallsBack() {
        let a = actions([Self.begin(now: Self.native), .snapshotTaken(ok: true, time: 0), .wrote(changeCount: 7, time: 0), .keyFailed(time: 0.01)])
        #expect(a.suffix(2) == [.restoreClipboard, .insertViaAccessibility("hello ", Self.native)])
        let b = actions([Self.begin(), .snapshotTaken(ok: true, time: 0), .wrote(changeCount: 7, time: 0), .keyFailed(time: 0.01)])
        #expect(b.suffix(3) == [.restoreClipboard, .showCard("hello", .cannotPostKeys), .dispatched(.card(.cannotPostKeys))])
    }

    @Test func noKeyPermissionUsesAccessibilityOrCard() {
        let env = M.Environment(clipboard: .allowed, canPostKeys: false)
        #expect(actions([Self.begin(now: Self.native, env: env)]).first == .insertViaAccessibility("hello ", Self.native))
        #expect(actions([Self.begin(env: env)]).first == .showCard("hello", .cannotPostKeys))
    }

    @Test func accessibilityFailureShowsTheCard() {
        let env = M.Environment(clipboard: .denied, canPostKeys: true)
        let a = actions([Self.begin(now: Self.native, env: env), .accessibilityInserted(ok: false, time: 0.02)])
        #expect(a.contains(.showCard("hello", .accessibilityInsertFailed)))
    }

    @Test func preferAccessibilitySkipsTheClipboard() {
        var config = M.Config()
        config.preferAccessibility = true
        #expect(actions([Self.begin(now: Self.native)], config: config).first == .insertViaAccessibility("hello ", Self.native))
        #expect(actions([Self.begin()], config: config).first == .snapshotClipboard)  // Chromium: paste only
    }

    // MARK: Back-to-back takes

    @Test func supersedeHandsTheSnapshotOver() {
        let a = actions(Self.pasteToKey + [.supersede(time: 0.1)])
        #expect(a.suffix(2).first == .handOffSnapshot)
        #expect(settlement(a)?.clipboard == .handedOff)
    }

    @Test func carriedSnapshotSkipsTheReadAndIsRestoredLater() {
        let a = actions([Self.begin(carried: true), .wrote(changeCount: 9, time: 0), .keyPosted(time: 0.01),
                         .clipboardRead(time: 0.02), .restored(ok: true, time: 0.31)])
        #expect(a.first == .writeTransient("hello "))
        #expect(!a.contains(.snapshotClipboard))
        #expect(a.contains(.restoreClipboard))
    }

    @Test func carriedSnapshotIsRestoredWhenTheNextTakeGoesToTheCard() {
        var none = Self.field
        none.kind = .notText
        #expect(actions([Self.begin(now: none, carried: true)]).first == .restoreClipboard)
        #expect(actions([Self.begin("  ", carried: true)]).contains(.restoreClipboard))
    }

    @Test func emptyTextDoesNothing() {
        let a = actions([Self.begin("  \n ")])
        #expect(a.first == .dispatched(.empty))
        #expect(settlement(a)?.clipboard == .untouched)
    }

    // MARK: Invariants over random timelines

    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test func randomTimelinesKeepTheClipboardSafe() {
        var rng = RNG(state: 42)
        let kinds: [FocusInfo.Kind] = [.editableText, .secureText, .notText, .unknown]
        let engines: [FocusInfo.Engine] = [.native, .web, .unknown]
        let access: [M.ClipboardAccess] = [.allowed, .wouldPrompt, .denied]
        for _ in 0..<3000 {
            var config = M.Config()
            config.unreadableClipboard = Bool.random(using: &rng) ? .card : .pasteWithoutRestore
            config.preferAccessibility = Bool.random(using: &rng)
            var m = M(config: config)
            func focus() -> FocusInfo {
                FocusInfo(kind: kinds.randomElement(using: &rng)!, engine: engines.randomElement(using: &rng)!,
                          pid: Int32.random(in: 1...2, using: &rng), canSetSelectedText: Bool.random(using: &rng))
            }
            let carried = Int.random(in: 0..<5, using: &rng) == 0
            let now = focus()
            var t = 0.0
            var all: [A] = m.handle(.begin(text: "hi", start: focus(), now: now,
                                           env: .init(clipboard: access.randomElement(using: &rng)!, canPostKeys: Bool.random(using: &rng)),
                                           carriedSnapshot: carried, time: t))
            var snapshots = carried ? 1 : 0, restores = 0, writes = 0, settled = 0
            var external = false
            var actionsAfterSettle = 0
            var count = 0
            for _ in 0..<12 {
                t += Double.random(in: 0...1.5, using: &rng)
                let input: I
                switch Int.random(in: 0..<13, using: &rng) {
                case 0: input = .snapshotTaken(ok: Int.random(in: 0..<6, using: &rng) > 0, time: t)
                case 1: count += 1; input = .wrote(changeCount: count, time: t)
                case 2: input = .keyPosted(time: t)
                case 3: input = .keyFailed(time: t)
                case 4, 5: input = .clipboardRead(time: t)
                case 6: input = .changeCount(Bool.random(using: &rng) ? count : count + 100, time: t)
                case 7: input = .accessibilityInserted(ok: Bool.random(using: &rng), time: t)
                case 8: input = .cardPasteWhenField(time: t)
                case 9: input = .fieldFocused(focus(), time: t)
                case 10: input = .supersede(time: t)
                case 11: input = .cardDismissed(time: t)
                default: input = .tick(time: t)
                }
                if case .snapshotTaken(true, _) = input { external = false }
                if case .changeCount(let c, _) = input, let ours = m.ourChangeCount, c != ours, m.holdsSnapshot { external = true }
                let before = settled
                var acts = m.handle(input)
                // Feed restore results back, as the Inserter does.
                if acts.contains(.restoreClipboard) { acts += m.handle(.restored(ok: true, time: t)) }
                if before > 0 { actionsAfterSettle += acts.count }
                for a in acts {
                    switch a {
                    case .snapshotClipboard: break
                    case .restoreClipboard: restores += 1; #expect(!external, "restored after an external change")
                    case .writeTransient:
                        writes += 1
                        // A write needs a snapshot to restore, unless the user allowed otherwise.
                        // After the copy for the card the clipboard already holds this text, by design.
                        if config.unreadableClipboard == .card, !m.copiedForCard { #expect(m.holdsSnapshot, "write without a snapshot") }
                    case .postPaste:
                        break
                    case .settled: settled += 1
                    default: break
                    }
                }
                if case .snapshotTaken(true, _) = input, acts.contains(where: { if case .writeTransient = $0 { true } else { false } }) { snapshots += 1 }
                all += acts
            }
            #expect(restores <= snapshots, "more restores than snapshots")
            #expect(settled <= 1)
            #expect(actionsAfterSettle == 0)
            if now.kind == .secureText {
                // The only way to a paste is the card's "Paste when I click a field".
                let paste = all.firstIndex { if case .postPaste = $0 { true } else { false } }
                let arm = all.firstIndex { if case .armFieldWatch = $0 { true } else { false } }
                if let paste { #expect(arm.map { $0 < paste } == true, "pasted into a secure field") }
            }
        }
    }

    @Test func neverPastesIntoASecureField() {
        var secure = Self.field
        secure.kind = .secureText
        let inputs: [I] = [Self.begin(now: secure), .snapshotTaken(ok: true, time: 0), .wrote(changeCount: 1, time: 0), .keyPosted(time: 0)]
        let a = actions(inputs)
        #expect(!a.contains { if case .postPaste = $0 { true } else { false } })
        #expect(!a.contains { if case .writeTransient = $0 { true } else { false } })
    }
}
