import AppKit
import Foundation
import SaylarkCore

// Active mode: the take's text goes in at the cursor through the `Inserter` (snapshot the
// clipboard, paste, wait for the target's read, restore), or onto the card when it can't.

extension ShadowEngine {
    /// Dictation apps that listen to Fn by default and paste: running one next to Active mode on
    /// Fn means both paste. Bundle IDs read from the apps' Info.plists in /Applications
    /// (superwhisper was not installed here; its ID is the one it ships with).
    public nonisolated static let knownDictationApps: [(bundleID: String, name: String)] = [
        ("com.electron.wispr-flow", "Wispr Flow"),
        ("com.electron.aqua-voice", "Aqua Voice"),
        ("com.seewillow.WillowMac", "Willow Voice"),
        ("com.pais.handy", "Handy"),
        ("com.superduper.superwhisper", "superwhisper"),
    ]

    /// The name of a running dictation app that would also act on `trigger`, if any. Only Fn
    /// clashes: the right-hand modifiers are Saylark's own.
    public nonisolated static func triggerClash(trigger: TriggerKey, running: [String]) -> String? {
        guard trigger == .fn else { return nil }
        let set = Set(running)
        return knownDictationApps.first { set.contains($0.bundleID) }?.name
    }

    // MARK: - DictationEngine (Active mode)

    public func activeReadiness() -> ActiveReadiness {
        let env = inserter.parts.environment()
        return ActiveReadiness(
            accessibility: env.canPostKeys, clipboard: ClipboardAccess(env.clipboard),
            triggerClash: Self.triggerClash(trigger: triggerKey, running: parts.runningApps()))
    }

    public func requestClipboardAccess() async -> ClipboardAccess {
        ClipboardAccess(inserter.parts.pasteboard.requestAccess())
    }

    public func cardCopy() {
        guard let c = card else { return }
        inserter.cardCopy()
        continuation.yield(.pill(.copied, take: c.take))
        setOutcome(c.take, .copied)
    }

    public func cardPasteWhenField() {
        guard card != nil else { return }
        card?.waiting = true
        inserter.cardPasteWhenField()
        continuation.yield(.pill(.pasteWhenFocused, take: card?.take))
    }

    public func cardDismiss() {
        guard let c = card else { return }
        card?.waiting = false
        inserter.cardDismiss()
        continuation.yield(.pill(.dismiss, take: c.take))
    }

    /// Pastes a past take's clean text at the cursor now, through the same insertion path. A
    /// cancelled take still being transcribed is waited for; a take with no text but saved audio
    /// is transcribed first. A take that had not gone anywhere (cancelled, card, copied, failed)
    /// is marked `.inserted` once pasted.
    @discardableResult
    public func paste(_ id: UUID) async -> DictationOutcome {
        if let pending = inflight[id] { await pending.value }
        guard var record = try? await store.record(id) else { return .empty }
        if record.cleanText.isEmpty, store.audioURL(for: record) != nil, let again = try? await retranscribe(id) {
            record = again
        }
        let text = record.cleanText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .empty }
        // No card is shown for a paste from the menu, so nothing would say the text was copied.
        let result = await inserter.insert(text, context: .init(copyWhenNoField: false))
        switch result.outcome {
        case .pasted, .insertedViaAccessibility:
            if result.outcome == .pasted { pastedTakes[result.id] = id }
            if [.cancelled, .card, .copied, .failed, .empty].contains(record.outcome) { setOutcome(id, .inserted) }
            return .inserted
        case .noField(let r), .failed(let r):
            // The pill is not up for a paste from the menu, so there is no card to show: close the
            // insertion's card at once (the text stays in the Library) and say why when a
            // permission is the cause.
            let cause = CardCause(r)
            noticeSink.yield(.card(take: id, cause: cause))
            switch cause {
            case .accessibilityOff: continuation.yield(.pill(.fail(.accessibilityOff), take: id))
            case .clipboardBlocked: continuation.yield(.pill(.fail(.clipboardAccessOff), take: id))
            default: break
            }
            inserter.cardDismiss()
            return .card
        case .empty:
            return .empty
        }
    }

    // MARK: - Delivering a take

    struct Delivery {
        var outcome: DictationOutcome
        /// Release → ⌘V posted (or the card), ms: the record's `releaseToTextMs` in Active mode.
        var releaseMs: Double
        var sent: Bool
        var metrics: InsertionMetrics
        var settled: Task<InsertionMachine.Settlement, Never>?
    }

    /// Inserts the take's text (or shows the card), sends the pill outcome, and for dictate and
    /// send presses Return once the target has read the text.
    func deliver(_ t: Take, clean: String, failed: Bool, released: Double, send: Bool, textMs: Double) async -> Delivery {
        var m = InsertionMetrics(outcome: "")
        m.textMs = textMs
        m.returnArmed = t.returnArmed
        m.sendRequested = send
        func skip(_ why: SendSkip) {
            guard send else { return }
            m.sendSkipped = why.rawValue
            noticeSink.yield(.sendSkipped(take: t.id, why: why))
        }
        if failed {
            // The audio is saved; the Library can transcribe it again. Partial text is not pasted.
            m.outcome = "failed"
            continuation.yield(.pill(.fail(.transcriptionFailed), take: t.id))
            skip(.failed)
            return Delivery(outcome: .failed, releaseMs: textMs, sent: false, metrics: m)
        }
        if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            m.outcome = "empty"
            continuation.yield(.pill(.finish(.empty), take: t.id))
            skip(.empty)
            return Delivery(outcome: .empty, releaseMs: textMs, sent: false, metrics: m)
        }
        let start = await t.focus?.value
        let copy = parts.defaults.object(forKey: DictationSettingsKey.copyWhenNoField) as? Bool ?? false
        let result = await inserter.insert(clean, context: .init(focusAtStart: start, copyWhenNoField: copy))
        let dispatchedAt = HotkeyClock.now
        let releaseMs = (dispatchedAt - released) * 1000
        m.releaseToPasteMs = releaseMs
        m.insertCallMs = result.callToDispatchMs
        switch result.outcome {
        case .pasted, .insertedViaAccessibility:
            let pasted = result.outcome == .pasted
            if pasted { pastedTakes[result.id] = t.id }
            m.outcome = pasted ? "pasted" : "accessibility"
            continuation.yield(.pill(.finish(.inserted), take: t.id))
            var sent = false
            if send {
                // Return only after the app has read our text: sooner, it would send the box
                // without it. No read within the cap: the paste did not land, so no Return.
                var read = true
                if pasted {
                    read = await Self.first(result.read, within: parts.send.readCap)
                    m.readWaitMs = (HotkeyClock.now - dispatchedAt) * 1000
                    if read, parts.send.delayAfterRead > 0 { try? await Task.sleep(for: .seconds(parts.send.delayAfterRead)) }
                }
                if read {
                    do {
                        try await inserter.parts.keys.postReturn(targetPID: result.focus.pid)
                        sent = true
                        m.releaseToReturnMs = (HotkeyClock.now - released) * 1000
                    } catch {
                        skip(.postFailed)
                    }
                } else {
                    skip(.notRead)
                }
            }
            return Delivery(outcome: .inserted, releaseMs: releaseMs, sent: sent, metrics: m, settled: result.settled)
        case .noField(let r), .failed(let r):
            let cause = CardCause(r)
            m.outcome = "card:\(cause.rawValue)"
            showCard(take: t.id, insertion: result.id)
            continuation.yield(.pill(.finish(cause.pillOutcome(result.cardText, copied: result.copiedToClipboard)), take: t.id))
            noticeSink.yield(.card(take: t.id, cause: cause))
            skip(.card)
            return Delivery(outcome: result.copiedToClipboard ? .copied : .card, releaseMs: releaseMs, sent: false, metrics: m, settled: result.settled)
        case .empty:
            m.outcome = "empty"
            continuation.yield(.pill(.finish(.empty), take: t.id))
            skip(.empty)
            return Delivery(outcome: .empty, releaseMs: releaseMs, sent: false, metrics: m, settled: result.settled)
        }
    }

    /// The card is up for `take`. If the app never closes it, the engine does after
    /// `Parts.cardTimeout`, so the insertion always settles.
    func showCard(take: UUID, insertion: UUID) {
        card = CardState(take: take, insertion: insertion)
        let timeout = parts.cardTimeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, self.card?.insertion == insertion else { return }
            self.cardDismiss()
        }
    }

    /// The insertion's final account, into the saved take's metrics.
    func recordSettlement(_ id: UUID, _ s: InsertionMachine.Settlement) async {
        let updated = try? await store.update(id) { _, metrics in
            guard var ins = metrics?.insertion else { return }
            ins.keyMs = s.keyMs
            ins.firstReadMs = s.firstReadMs
            ins.restoreMs = s.restoreMs
            ins.readConfirmed = s.readConfirmed
            ins.clipboard = s.clipboard.rawValue
            ins.viaCard = s.viaCard
            metrics?.insertion = ins
        }
        if updated != nil, let metrics = try? await store.metrics(for: id) { lastMetrics = metrics }
    }

    /// Later news from the insertion path: the card's text landed in a field, or the wait ended.
    func inserterEvent(_ event: InsertionEvent) {
        switch event {
        case .dispatched(let tx, let outcome):
            guard let c = card, c.insertion == tx else { return }
            switch outcome {
            case .pasted, .insertedViaAccessibility:
                card?.waiting = false
                continuation.yield(.pill(.fieldFocused, take: c.take))
                setOutcome(c.take, .inserted)
            default:
                break
            }
        case .card(let tx, _, let reason):
            // ⌘V went out but the app never read the text: the paste failed after the pill said
            // "inserted". The clipboard is already back; say so, keep the text in the Library.
            guard let take = pastedTakes[tx], reason == .pasteNotRead else { return }
            continuation.yield(.pill(.fail(.pasteFailed), take: take))
            noticeSink.yield(.pasteFailed(take: take))
            setOutcome(take, .card)
            inserter.cardDismiss()
        case .settled(let tx, let s):
            pastedTakes[tx] = nil
            guard let c = card, c.insertion == tx else { return }
            // "Paste when I click a field" ran out without a field: close the waiting pill.
            if c.waiting, !s.viaCard { continuation.yield(.pill(.dismiss, take: c.take)) }
            card = nil
        case .waitingForField, .fieldWaitEnded:
            break
        }
    }

    /// Changes a take's outcome: now if it is saved, else when its save lands.
    func setOutcome(_ id: UUID, _ outcome: DictationOutcome) {
        if saving.contains(id) {
            pendingOutcome[id] = outcome
            return
        }
        let store = self.store, events = continuation
        Task {
            if let r = try? await store.update(id, { r, _ in r.outcome = outcome }) { events.yield(.saved(r)) }
        }
    }

    /// Whether Return during a take in the app `bundleID` should stop, paste and send.
    func sendOnReturnApplies(to bundleID: String?) -> Bool {
        let setting = parts.defaults.string(forKey: DictationSettingsKey.sendOnReturn).flatMap(SendOnReturn.init(rawValue:)) ?? .listedApps
        switch setting {
        case .off: return false
        case .everywhere: return true
        case .listedApps:
            guard let bundleID else { return false }
            let apps = parts.defaults.stringArray(forKey: DictationSettingsKey.sendOnReturnApps) ?? DictationSettingsKey.defaultSendOnReturnApps
            return apps.contains(bundleID)
        }
    }

    /// `task`'s value, or false if it takes longer than `seconds`.
    nonisolated static func first(_ task: Task<Bool, Never>, within seconds: Double) async -> Bool {
        let once = Locked(false)
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            func resume(_ value: Bool) {
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { cont.resume(returning: value) }
            }
            Task { resume(await task.value) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                resume(false)
            }
        }
    }

    /// An `Inserter` that touches nothing: an in-memory clipboard, keys that go nowhere, focus
    /// unknown. The default for `Parts`, so nothing in a test or the CLI can reach the real
    /// clipboard or keyboard by accident.
    public static func inertInserter() -> Inserter {
        let pb = MemoryPasteboard()
        let probe = ScriptedFocusProbe([FocusInfo(kind: .unknown)])
        return Inserter(parts: .init(
            pasteboard: pb, keys: RecordingKeyPoster(), focus: probe, watcher: PollingFieldWatcher(probe: probe),
            accessibility: RecordingAccessibilityInserter(result: false),
            environment: { .init(clipboard: pb.access, canPostKeys: true) }))
    }
}

extension ClipboardAccess {
    init(_ access: InsertionMachine.ClipboardAccess) {
        switch access {
        case .allowed: self = .allowed
        case .wouldPrompt: self = .wouldAsk
        case .denied: self = .denied
        }
    }
}

extension CardCause {
    init(_ r: InsertionMachine.CardReason) {
        switch r {
        case .noTextField: self = .noTextField
        case .secureField: self = .secureField
        case .appChanged: self = .appChanged
        case .clipboardUnavailable: self = .clipboardBlocked
        case .cannotPostKeys: self = .accessibilityOff
        case .pasteNotRead: self = .pasteNotRead
        case .accessibilityInsertFailed: self = .accessibilityInsertFailed
        }
    }
}
