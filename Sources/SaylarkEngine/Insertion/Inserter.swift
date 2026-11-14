import AppKit
import SaylarkCore

// MARK: - How the engine calls this
//
// One `Inserter` for the app's lifetime (main actor). Build it with `Inserter(parts: .system())`;
// tests and `saylark insert-test` pass fakes or a named pasteboard instead.
//
// 1. Take start (Fn down, inside `begin()`), next to `frontmostApp()`:
//
//        let focusTask = Task { await inserter.captureFocus() }   // ≤ 0.1 s, off the main thread
//
//    Keep the task on the take (`Take.focusAtStart`). Never await it before showing the pill.
//
// 2. Release (inside `finish()`), right after `t.transcriber.finish()` returns the text and
//    BEFORE the m4a encode and the history save:
//
//        let start = await t.focusAtStart.value
//        let result = await inserter.insert(cleanText, context: .init(focusAtStart: start))
//        send.yield(.pill(.finish(result.pillOutcome)))
//        // then encode audio, save the record with `outcome: result.dictationOutcome`
//
//    `insert` returns as soon as ⌘V is posted (or the card decision is made). The clipboard
//    restore happens in the background; `await result.settled.value` gives the final account
//    (read receipt, restore, timings) for metrics. Don't hold the save for it.
//    Optional: start `inserter.captureFocus()` at release in parallel with the transcriber and
//    pass it as `context.focusNow` to save the probe's few milliseconds.
//
// 3. The card (outcome `.noField` / `.failed`): the pill shows `result.cardText` with Copy,
//    "Paste when I click a field" and Dismiss, and calls `cardCopy()`, `cardPasteWhenField()` or
//    `cardDismiss()`. With no text field the text is already on the clipboard
//    (`result.copiedToClipboard`, `Config.copyWhenNoField`) and the card says so. Later events (the text landed from the card, the wait expired) arrive on
//    `inserter.events`.
//
// 4. App quit: `inserter.flush()` puts the user's clipboard back if a restore is still pending.
//
// Takes are serialized: a second `insert` waits for the first to dispatch, then takes over its
// clipboard snapshot (so the user's content, not take 1's text, is what finally comes back).

/// What happened to the text, as soon as it is known.
public enum InsertionOutcome: Sendable, Equatable {
    /// ⌘V went to the target with our text on the clipboard.
    case pasted
    case insertedViaAccessibility
    /// No field to put it in (no text field, password field): the card is showing.
    case noField(InsertionMachine.CardReason)
    /// It could not go in safely (app changed, clipboard unreadable, no key permission, the
    /// paste was not read): the card is showing.
    case failed(InsertionMachine.CardReason)
    /// Nothing to insert.
    case empty

    init(_ o: InsertionMachine.Outcome) {
        switch o {
        case .pasted: self = .pasted
        case .insertedViaAccessibility: self = .insertedViaAccessibility
        case .empty: self = .empty
        case .card(let r) where r == .noTextField || r == .secureField: self = .noField(r)
        case .card(let r): self = .failed(r)
        }
    }

    public var showsCard: Bool {
        switch self {
        case .noField, .failed: true
        default: false
        }
    }
}

public struct InsertionContext: Sendable {
    /// Focus captured at take start (`captureFocus()`); nil if not captured.
    public var focusAtStart: FocusInfo?
    /// Focus at insert time, if the caller already probed it. Probed here otherwise.
    public var focusNow: FocusInfo?
    /// Overrides `Config.copyWhenNoField` for this insertion (nil keeps the config's value).
    public var copyWhenNoField: Bool?
    public init(focusAtStart: FocusInfo? = nil, focusNow: FocusInfo? = nil, copyWhenNoField: Bool? = nil) {
        self.focusAtStart = focusAtStart
        self.focusNow = focusNow
        self.copyWhenNoField = copyWhenNoField
    }
}

public struct InsertionResult: Sendable {
    public var id: UUID
    public var outcome: InsertionOutcome
    /// The (unspaced) text, for the card.
    public var cardText: String
    /// No text field: the text was put on the clipboard and left there for the user.
    public var copiedToClipboard = false
    /// Focus at insert time.
    public var focus: FocusInfo
    /// Milliseconds from the `insert` call to ⌘V posted (or to the card/AX decision).
    public var callToDispatchMs: Double
    /// The final account: read receipt, restore, timings (ms from the `insert` call).
    public let settled: Task<InsertionMachine.Settlement, Never>

    public var pillOutcome: PillOutcome {
        switch outcome {
        case .pasted, .insertedViaAccessibility: .inserted
        case .noField, .failed: copiedToClipboard ? .noTextFieldCopied(cardText) : .noTextField(cardText)
        case .empty: .empty
        }
    }

    public var dictationOutcome: DictationOutcome {
        switch outcome {
        case .pasted, .insertedViaAccessibility: .inserted
        case .noField, .failed: copiedToClipboard ? .copied : .card
        case .empty: .empty
        }
    }

    /// True once the target has read our text (the read receipt); false if the insertion ended
    /// (card, settled) without a read. Dictate-and-send presses Return only after `true`.
    public let read: Task<Bool, Never>
}

public enum InsertionEvent: Sendable, Equatable {
    /// Text landed later (from the card's "Paste when I click a field").
    case dispatched(UUID, InsertionOutcome)
    case card(UUID, text: String, reason: InsertionMachine.CardReason)
    case waitingForField(UUID)
    case fieldWaitEnded(UUID)
    case settled(UUID, InsertionMachine.Settlement)
}

@MainActor
public final class Inserter {
    public struct Parts {
        public var pasteboard: any Pasteboard
        public var keys: any KeyPoster
        public var focus: any FocusProbe
        public var watcher: any FieldWatcher
        public var accessibility: any AccessibilityInserter
        /// Checked at every insert: clipboard privacy and key-posting permission.
        public var environment: @MainActor () -> InsertionMachine.Environment
        /// Seconds on a monotonic clock.
        public var now: @Sendable () -> Double

        public init(pasteboard: any Pasteboard, keys: any KeyPoster, focus: any FocusProbe, watcher: any FieldWatcher,
                    accessibility: any AccessibilityInserter, environment: @escaping @MainActor () -> InsertionMachine.Environment,
                    now: @escaping @Sendable () -> Double = { HotkeyClock.now }) {
            self.pasteboard = pasteboard
            self.keys = keys
            self.focus = focus
            self.watcher = watcher
            self.accessibility = accessibility
            self.environment = environment
            self.now = now
        }

        /// The real system: the general pasteboard, ⌘V into the HID stream, accessibility focus.
        /// Production only.
        @MainActor
        public static func system() -> Parts {
            let pasteboard = SystemPasteboard.general()
            let probe = AXFocusProbe()
            return Parts(
                pasteboard: pasteboard, keys: SystemKeyPoster(), focus: probe,
                watcher: PollingFieldWatcher(probe: probe), accessibility: AXTextInserter(),
                environment: { .init(clipboard: pasteboard.access, canPostKeys: CGPreflightPostEventAccess()) })
        }
    }

    public let parts: Parts
    private nonisolated let probe: any FocusProbe
    public let config: InsertionMachine.Config
    public let events: AsyncStream<InsertionEvent>
    private let eventSink: AsyncStream<InsertionEvent>.Continuation
    /// How often the clipboard's change count is polled while our text is up.
    public var pollInterval = 0.05

    private var current: Transaction?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(parts: Parts, config: InsertionMachine.Config = .init()) {
        self.parts = parts
        self.probe = parts.focus
        self.config = config
        (events, eventSink) = AsyncStream.makeStream()
    }

    /// Call at take start. Off the main thread, ≤ the probe's timeout.
    public nonisolated func captureFocus() async -> FocusInfo {
        await probe.focused()
    }

    /// Puts `text` into the focused field. Returns once ⌘V is posted, the accessibility insert is
    /// done, or the card is decided; the clipboard restore continues in the background.
    public func insert(_ text: String, context: InsertionContext = .init()) async -> InsertionResult {
        let called = parts.now()
        await acquire()
        defer { release() }

        // A previous insertion still waiting to restore: take over its snapshot.
        var carried: (snapshot: PasteboardSnapshot, ours: Int)?
        if let previous = current, !previous.machine.isDone {
            await previous.idle()
            if previous.machine.watchesClipboard { previous.send(.changeCount(parts.pasteboard.changeCount, time: parts.now())) }
            await previous.idle()
            previous.send(.supersede(time: parts.now()))
            await previous.idle()
            if let handed = previous.handedOff { carried = handed }
        }

        var now = context.focusNow
        if now == nil { now = await parts.focus.focused() }
        let focus = now!
        var config = self.config
        if let copy = context.copyWhenNoField { config.copyWhenNoField = copy }
        let tx = Transaction(inserter: self, machine: InsertionMachine(config: config))
        if let carried {
            tx.snapshot = carried.snapshot
            tx.ours = carried.ours
        }
        current = tx
        let outcome = await withCheckedContinuation { (cont: CheckedContinuation<InsertionMachine.Outcome, Never>) in
            tx.onDispatch = cont
            tx.send(.begin(text: text, start: context.focusAtStart, now: focus, env: parts.environment(),
                           carriedSnapshot: carried != nil, time: called))
        }
        let dispatchedAt = parts.now()
        return InsertionResult(
            id: tx.id, outcome: InsertionOutcome(outcome), cardText: text.trimmingCharacters(in: .whitespacesAndNewlines),
            copiedToClipboard: tx.machine.copiedForCard, focus: focus, callToDispatchMs: (dispatchedAt - called) * 1000, settled: tx.settledTask, read: tx.readTask)
    }

    // MARK: Card buttons (act on the latest insertion)

    public func cardCopy() { current?.send(.cardCopy(time: parts.now())) }
    public func cardPasteWhenField() { current?.send(.cardPasteWhenField(time: parts.now())) }
    public func cardDismiss() { current?.send(.cardDismissed(time: parts.now())) }

    /// Restores the user's clipboard now if a restore is pending (app quit).
    public func flush() async {
        guard let tx = current, !tx.machine.isDone else { return }
        await tx.idle()
        tx.send(.supersede(time: parts.now()))
        await tx.idle()
        if let handed = tx.handedOff {
            _ = parts.pasteboard.restore(handed.snapshot, ifChangeCount: handed.ours)
        }
    }

    // MARK: Serializing inserts

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    fileprivate func emit(_ event: InsertionEvent) { eventSink.yield(event) }
}

/// One insertion: the machine plus the effects it asks for.
@MainActor
private final class Transaction {
    let id = UUID()
    /// Weak: a pending restore must still happen if the Inserter goes away, so the transaction
    /// keeps its own parts and only uses the Inserter to publish events.
    weak var inserter: Inserter?
    let parts: Inserter.Parts
    let pollInterval: Double
    var machine: InsertionMachine
    var snapshot: PasteboardSnapshot?
    /// Change count of our transient write (or the one handed over with the snapshot).
    var ours: Int?
    var handedOff: (snapshot: PasteboardSnapshot, ours: Int)?
    var onDispatch: CheckedContinuation<InsertionMachine.Outcome, Never>?
    let settledTask: Task<InsertionMachine.Settlement, Never>
    private let settledSink: AsyncStream<InsertionMachine.Settlement>.Continuation
    let readTask: Task<Bool, Never>
    private let readSink: AsyncStream<Bool>.Continuation
    private var readReported = false
    private var inbox: [InsertionMachine.Input] = []
    private var pumping = false
    private var timer: Task<Void, Never>?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Holds the transaction until it settles, so a pending restore happens even if nobody else
    /// keeps a reference (the Inserter released, the engine moved on).
    private var keepAlive: Transaction?

    init(inserter: Inserter, machine: InsertionMachine) {
        self.inserter = inserter
        self.parts = inserter.parts
        self.pollInterval = inserter.pollInterval
        self.machine = machine
        let (stream, sink) = AsyncStream<InsertionMachine.Settlement>.makeStream()
        settledSink = sink
        settledTask = Task { for await s in stream { return s }; return .init(outcome: .empty, readConfirmed: false, clipboard: .untouched, viaCard: false) }
        let (reads, readSink) = AsyncStream<Bool>.makeStream()
        self.readSink = readSink
        readTask = Task { for await r in reads { return r }; return false }
        keepAlive = self
    }

    /// Queues an input. Inputs are handled one at a time, in order, with each batch of actions
    /// performed before the next input.
    func send(_ input: InsertionMachine.Input) {
        inbox.append(input)
        guard !pumping else { return }
        pumping = true
        Task { @MainActor in await pump() }
    }

    /// Waits until queued inputs are handled.
    func idle() async {
        if !pumping, inbox.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func pump() async {
        while !inbox.isEmpty {
            let input = inbox.removeFirst()
            for action in machine.handle(input) { await perform(action) }
            if machine.readConfirmed { reportRead(true) }
        }
        pumping = false
        scheduleTimer()
        let waiting = idleWaiters
        idleWaiters = []
        for w in waiting { w.resume() }
    }

    private func perform(_ action: InsertionMachine.Action) async {
        let pb = parts.pasteboard
        switch action {
        case .snapshotClipboard:
            do {
                snapshot = try pb.snapshot()
                inbox.append(.snapshotTaken(ok: true, time: parts.now()))
            } catch {
                inbox.append(.snapshotTaken(ok: false, time: parts.now()))
            }

        case .writeTransient(let text):
            // A snapshot taken a moment ago is stale if the user copied in between: take it again.
            if let s = snapshot, ours == nil, pb.changeCount != s.changeCount, let fresh = try? pb.snapshot() { snapshot = fresh }
            let count = pb.writeTransient(text) { [weak self] in
                guard let self else { return }
                self.send(.clipboardRead(time: self.parts.now()))
            }
            ours = count
            inbox.append(.wrote(changeCount: count, time: parts.now()))

        case .postPaste(let pid):
            do {
                try await parts.keys.postPaste(targetPID: pid)
                inbox.append(.keyPosted(time: parts.now()))
            } catch {
                inbox.append(.keyFailed(time: parts.now()))
            }

        case .restoreClipboard:
            var ok = false
            if let s = snapshot, let ours { ok = pb.restore(s, ifChangeCount: ours) }
            snapshot = nil
            inbox.append(.restored(ok: ok, time: parts.now()))

        case .dropSnapshot:
            snapshot = nil

        case .handOffSnapshot:
            if let s = snapshot, let ours { handedOff = (s, ours) }
            snapshot = nil

        case .insertViaAccessibility(let text, let target):
            let ok = await parts.accessibility.insert(text, expected: target)
            inbox.append(.accessibilityInserted(ok: ok, time: parts.now()))

        case .showCard(let text, let reason):
            reportRead(false)
            inserter?.emit(.card(id, text: text, reason: reason))

        case .copyToClipboard(let text):
            pb.writePlain(text)

        case .armFieldWatch(let until):
            inserter?.emit(.waitingForField(id))
            parts.watcher.watch(timeout: max(0, until - parts.now())) { [weak self] info in
                guard let self else { return }
                self.send(.fieldFocused(info, time: self.parts.now()))
            }

        case .disarmFieldWatch:
            parts.watcher.cancel()
            inserter?.emit(.fieldWaitEnded(id))

        case .dispatched(let outcome):
            if let cont = onDispatch {
                onDispatch = nil
                cont.resume(returning: outcome)
            } else {
                inserter?.emit(.dispatched(id, InsertionOutcome(outcome)))
            }

        case .settled(let s):
            reportRead(s.readConfirmed)
            timer?.cancel()
            settledSink.yield(s)
            settledSink.finish()
            inserter?.emit(.settled(id, s))
            keepAlive = nil
        }
    }

    /// Resolves `readTask` once: the first read receipt, or the end without one.
    private func reportRead(_ read: Bool) {
        guard !readReported else { return }
        readReported = true
        readSink.yield(read)
        readSink.finish()
    }

    /// Wakes for the machine's deadline, and polls the change count while our text is up.
    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        guard !machine.isDone else { return }
        let watching = machine.watchesClipboard
        guard watching || machine.deadline != nil else { return }
        let now = parts.now()
        var wake = machine.deadline ?? .infinity
        if watching { wake = min(wake, now + pollInterval) }
        let delay = max(0, wake - now)
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.machine.isDone else { return }
            if self.machine.watchesClipboard { self.send(.changeCount(self.parts.pasteboard.changeCount, time: self.parts.now())) }
            self.send(.tick(time: self.parts.now()))
        }
    }
}
