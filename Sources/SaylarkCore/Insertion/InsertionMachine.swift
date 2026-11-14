/// Decides how one piece of dictated text gets into the focused app, and when the user's
/// clipboard comes back. Pure: the Engine's `Inserter` performs each action, feeds back what
/// happened, and sends `.tick` at `deadline`. Times are seconds on one monotonic clock.
///
/// The paste path, in order:
/// 1. `.snapshotClipboard`: keep everything the user had on the clipboard (only when reading the
///    clipboard will not show the macOS privacy prompt).
/// 2. `.writeTransient`: put our text up as a promise, marked transient so clipboard managers
///    skip it. The promise tells us the moment the target app reads it (the read receipt).
/// 3. `.postPaste`: ⌘V. The caller returns to the engine here (`.dispatched(.pasted)`).
/// 4. Wait for the receipt. Restore `quietAfterRead` after the last read (Chromium reads twice),
///    and never sooner than `minHoldAfterKey` after ⌘V.
/// 5. `.restoreClipboard`, only if nothing else changed the clipboard meanwhile. If something
///    did, the clipboard now holds what the user (or another app) put there: leave it.
/// 6. No read within `readTimeout`: the paste did not land. Restore, then show the card.
///
/// Rules that never bend:
/// - The user's clipboard is never overwritten unless we hold a snapshot to restore it from
///   (except with the opt-in `.pasteWithoutRestore` policy, or the card's explicit Copy).
/// - Never paste into a password field.
/// - Never paste into a different app from the one that had focus when the take started
///   (unless `allowAcrossAppSwitch`): the card offers "Paste when I click a field" instead.
/// - Accessibility insertion only into native fields (never Electron/Chromium, where the write
///   "succeeds" without the page's own state seeing it).
///
/// The card and the clipboard. When no text field has focus (or the user switched apps while
/// talking), the text goes on the clipboard by default and stays there, the way Wispr Flow does
/// it: the card says "Copied" and ⌘V puts it anywhere (`Config.copyWhenNoField`). Password
/// fields are left out (dictated text next to a password field may be one, and clipboard
/// managers would keep it), and so are the permission cards. "Paste when I click a field" then
/// goes through the normal snapshot-and-restore path, so the clipboard ends up holding the
/// dictated text again (or whatever the user copied since), never an older clipboard.
/// With `copyWhenNoField` off, the card offers **Copy** (an explicit overwrite) instead.
public struct InsertionMachine: Sendable {
    public struct Config: Sendable, Equatable {
        /// Restore this long after the last read receipt (Chromium reads twice: probe, then read).
        public var quietAfterRead: Double = 0.2
        /// Never restore sooner than this after ⌘V, even after an early receipt.
        public var minHoldAfterKey: Double = 0.3
        /// No read receipt this long after ⌘V: the paste did not land. Restore and show the card.
        /// Long on purpose: a slow app that reads after we restore would paste the user's old
        /// clipboard, which is worse than a late card.
        public var readTimeout: Double = 3.0
        /// The only read came before ⌘V (a clipboard manager that ignored the transient
        /// markers, so later reads are served from the pasteboard server's cache and are
        /// invisible to us). Restore this long after ⌘V, and don't claim the paste failed.
        public var holdWhenReadBeforeKey: Double = 1.0
        /// "Paste when I click a field" gives up after this long.
        public var fieldWaitTimeout: Double = 20
        public var trailingSpace = true
        /// Paste even if the focused app changed since the take started.
        public var allowAcrossAppSwitch = false
        /// Use accessibility insertion first in native fields (no clipboard at all). Off by
        /// default: ⌘V is what every app handles the same way, including undo.
        public var preferAccessibility = false
        public var unreadableClipboard: UnreadableClipboardPolicy = .card
        /// No text field (or the app changed during the take): put the text on the clipboard and
        /// leave it there, then show the card.
        public var copyWhenNoField = false

        public init() {}
    }

    /// What to do when the clipboard can't be read without a prompt (so it can't be restored)
    /// and accessibility insertion is not possible.
    public enum UnreadableClipboardPolicy: Sendable, Equatable {
        /// Show the card. Nothing on the clipboard changes. The default.
        case card
        /// Paste anyway and leave our text on the clipboard. Only with the user's consent.
        case pasteWithoutRestore
    }

    /// Whether the clipboard's contents can be read for a snapshot (macOS pasteboard privacy).
    public enum ClipboardAccess: Sendable, Equatable {
        case allowed
        /// Reading would show the system "paste from other apps" prompt.
        case wouldPrompt
        case denied
    }

    /// Facts about the system at insert time.
    public struct Environment: Sendable, Equatable {
        public var clipboard: ClipboardAccess
        /// Synthetic key events can be posted (Accessibility / PostEvent permission).
        public var canPostKeys: Bool
        public init(clipboard: ClipboardAccess, canPostKeys: Bool) {
            self.clipboard = clipboard
            self.canPostKeys = canPostKeys
        }
    }

    /// Why the card is showing.
    public enum CardReason: String, Sendable, Equatable {
        case noTextField
        case secureField
        /// The focused app changed between the start of the take and now.
        case appChanged
        /// The clipboard can't be read without a prompt and accessibility insertion isn't possible.
        case clipboardUnavailable
        /// Synthetic keys can't be posted and accessibility insertion isn't possible.
        case cannotPostKeys
        /// ⌘V was sent but the target never read the clipboard.
        case pasteNotRead
        case accessibilityInsertFailed
    }

    public enum Outcome: Sendable, Equatable {
        case pasted
        case insertedViaAccessibility
        case card(CardReason)
        case empty
    }

    /// What became of the user's clipboard.
    public enum ClipboardResult: String, Sendable, Equatable {
        /// Never touched.
        case untouched
        /// Our text was replaced by the user's snapshot.
        case restored
        /// Someone else wrote to the clipboard while ours was up; their content stays.
        case leftExternalChange
        /// The next insertion took over the snapshot and will restore it.
        case handedOff
        /// Our text stays (`.pasteWithoutRestore`).
        case notRestorable
        /// The user pressed Copy on the card.
        case copiedByUser
        /// No text field: the text was put on the clipboard for the user and left there.
        case copiedForCard
    }

    /// The final account of one insertion. Times are milliseconds after `.begin`.
    public struct Settlement: Sendable, Equatable {
        public var outcome: Outcome
        public var readConfirmed: Bool
        public var keyMs: Double?
        public var firstReadMs: Double?
        public var restoreMs: Double?
        public var clipboard: ClipboardResult
        /// The text went in after the user chose "Paste when I click a field".
        public var viaCard: Bool

        public init(outcome: Outcome, readConfirmed: Bool, keyMs: Double? = nil, firstReadMs: Double? = nil,
                    restoreMs: Double? = nil, clipboard: ClipboardResult, viaCard: Bool) {
            self.outcome = outcome
            self.readConfirmed = readConfirmed
            self.keyMs = keyMs
            self.firstReadMs = firstReadMs
            self.restoreMs = restoreMs
            self.clipboard = clipboard
            self.viaCard = viaCard
        }
    }

    public enum Input: Sendable, Equatable {
        /// Start. `start` is the focus captured when the take began; `now` is the focus at insert
        /// time. `carriedSnapshot`: a previous insertion handed over its snapshot (its text is on
        /// the clipboard now, and the user's content waits to be restored).
        case begin(text: String, start: FocusInfo?, now: FocusInfo, env: Environment, carriedSnapshot: Bool, time: Double)
        case snapshotTaken(ok: Bool, time: Double)
        /// Our transient item is on the clipboard with this change count.
        case wrote(changeCount: Int, time: Double)
        case keyPosted(time: Double)
        case keyFailed(time: Double)
        /// The target read our promised text.
        case clipboardRead(time: Double)
        /// The clipboard's change count, polled.
        case changeCount(Int, time: Double)
        /// Result of `.restoreClipboard`: false when its own change-count guard refused.
        case restored(ok: Bool, time: Double)
        case accessibilityInserted(ok: Bool, time: Double)
        case cardCopy(time: Double)
        case cardPasteWhenField(time: Double)
        case cardDismissed(time: Double)
        case fieldFocused(FocusInfo, time: Double)
        /// A newer insertion is starting. Hand over the snapshot or wrap up.
        case supersede(time: Double)
        case tick(time: Double)
    }

    public enum Action: Sendable, Equatable {
        case snapshotClipboard
        case writeTransient(String)
        case postPaste(pid: Int32?)
        /// Put the snapshot back, guarded by our change count.
        case restoreClipboard
        /// Forget the snapshot: the clipboard is someone else's now.
        case dropSnapshot
        /// Give the snapshot to the next insertion.
        case handOffSnapshot
        case insertViaAccessibility(String, FocusInfo)
        /// Show the card with the (unspaced) text.
        case showCard(String, CardReason)
        /// The user pressed Copy: a normal, permanent clipboard write.
        case copyToClipboard(String)
        case armFieldWatch(until: Double)
        case disarmFieldWatch
        /// The first result is known: the caller can return.
        case dispatched(Outcome)
        /// Nothing more will happen. Always the last action.
        case settled(Settlement)
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case snapshotting
        case writing
        case posting
        /// ⌘V sent at `keyAt`; no receipt yet.
        case waitingForRead(keyAt: Double)
        /// Receipt seen; restore at `restoreAt` unless more reads come.
        case settling(keyAt: Double, restoreAt: Double)
        case restoring
        case accessibility
        case card(CardReason)
        case waitingForField(until: Double)
        case done
    }

    public let config: Config
    public private(set) var phase: Phase = .idle

    private var raw = ""
    private var text = ""
    private var target: FocusInfo?
    private var env = Environment(clipboard: .denied, canPostKeys: false)
    private var began = 0.0
    /// We hold the user's clipboard contents and must restore or hand them over.
    public private(set) var holdsSnapshot = false
    /// The change count of our own transient write.
    public private(set) var ourChangeCount: Int?
    /// The text was put on the clipboard on the way into the card (`Config.copyWhenNoField`).
    public private(set) var copiedForCard = false
    private var readBeforeKey = false
    private var keyAt: Double?
    private var firstReadAt: Double?
    private var restoredAt: Double?
    private var outcome: Outcome = .empty
    private var clipboard: ClipboardResult = .untouched
    private var viaCard = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// When the caller must send `.tick`.
    public var deadline: Double? {
        switch phase {
        case .waitingForRead(let keyAt):
            keyAt + (readBeforeKey ? config.holdWhenReadBeforeKey : config.readTimeout)
        case .settling(_, let restoreAt): restoreAt
        case .waitingForField(let until): until
        default: nil
        }
    }

    /// Our transient text is (or may be) on the clipboard and the caller should poll the change
    /// count and listen for read receipts.
    public var watchesClipboard: Bool {
        switch phase {
        case .waitingForRead, .settling, .posting: true
        default: false
        }
    }

    public var isDone: Bool { phase == .done }

    /// The target read our text after ⌘V started going out (the read receipt). Dictate-and-send
    /// waits for this before it presses Return.
    public var readConfirmed: Bool { firstReadAt != nil }

    public mutating func handle(_ input: Input) -> [Action] {
        if phase == .done { return [] }
        switch input {
        case .begin(let text, let start, let now, let env, let carried, let time):
            guard phase == .idle else { return [] }
            return begin(text: text, start: start, now: now, env: env, carried: carried, time: time)

        case .snapshotTaken(let ok, _):
            guard phase == .snapshotting else { return [] }
            if ok {
                holdsSnapshot = true
                phase = .writing
                return [.writeTransient(text)]
            }
            return fallback(.clipboardUnavailable)

        case .wrote(let count, _):
            guard phase == .writing else { return [] }
            ourChangeCount = count
            // With a snapshot, the clipboard result is set when it is restored, handed off or
            // taken over by someone else. Without one, our text stays.
            if !holdsSnapshot, clipboard != .copiedForCard { clipboard = .notRestorable }
            phase = .posting
            return [.postPaste(pid: target?.pid)]

        case .keyPosted(let time):
            guard phase == .posting else { return [] }
            keyAt = time
            outcome = .pasted
            if let read = firstReadAt {
                // The target read while the key events were still going out.
                phase = .settling(keyAt: time, restoreAt: max(read + config.quietAfterRead, time + config.minHoldAfterKey))
            } else {
                phase = .waitingForRead(keyAt: time)
            }
            return [.dispatched(.pasted)]

        case .keyFailed:
            guard phase == .posting else { return [] }
            // Our text is on the clipboard but no key went out: put the user's content back now.
            return fallback(.cannotPostKeys)

        case .clipboardRead(let time):
            switch phase {
            case .writing:
                // Before any key went out: not the target (a clipboard manager ignoring the
                // markers). Later reads are served from the pasteboard server's cache, unseen.
                readBeforeKey = true
            case .posting:
                // ⌘V is going out (the target can read between V-down and ⌘-up): a receipt.
                if firstReadAt == nil { firstReadAt = time }
            case .waitingForRead(let keyAt):
                firstReadAt = time
                phase = .settling(keyAt: keyAt, restoreAt: max(time + config.quietAfterRead, keyAt + config.minHoldAfterKey))
            case .settling(let keyAt, let restoreAt):
                phase = .settling(keyAt: keyAt, restoreAt: max(restoreAt, time + config.quietAfterRead))
            default:
                break
            }
            return []

        case .changeCount(let count, _):
            guard let ours = ourChangeCount, count != ours, holdsSnapshot || clipboard == .notRestorable || clipboard == .copiedForCard else { return [] }
            switch phase {
            case .waitingForRead, .settling, .posting:
                // Someone copied something while our text was up. It's theirs now: never restore
                // over it.
                return externalChange()
            default:
                return []
            }

        case .restored(let ok, let time):
            // Can arrive in any phase (restores also happen on the way into the card or AX).
            restoredAt = time
            holdsSnapshot = false
            // The restore on the way into the card came before the copy for the card: the
            // clipboard holds the dictated text now, which is the result that counts.
            if case .card = phase, clipboard == .copiedForCard { return [] }
            clipboard = ok ? .restored : .leftExternalChange
            if phase == .restoring { return settle() }
            return []

        case .accessibilityInserted(let ok, _):
            guard phase == .accessibility else { return [] }
            if ok {
                outcome = .insertedViaAccessibility
                return [.dispatched(.insertedViaAccessibility)] + settle()
            }
            return enterCard(.accessibilityInsertFailed)

        case .cardCopy:
            guard isCardShowing else { return [] }
            clipboard = .copiedByUser
            return [.copyToClipboard(raw)]

        case .cardPasteWhenField(let time):
            guard case .card = phase else { return [] }
            let until = time + config.fieldWaitTimeout
            phase = .waitingForField(until: until)
            return [.armFieldWatch(until: until)]

        case .cardDismissed:
            switch phase {
            case .card: return settle()
            case .waitingForField: return [.disarmFieldWatch] + settle()
            default: return []
            }

        case .fieldFocused(let info, _):
            guard case .waitingForField = phase, info.kind == .editableText else { return [] }
            viaCard = true
            return [.disarmFieldWatch] + route(to: info)

        case .supersede:
            switch phase {
            case .idle, .done: return []
            case .waitingForField:
                return [.disarmFieldWatch] + settle()
            default:
                if holdsSnapshot {
                    holdsSnapshot = false
                    clipboard = .handedOff
                    return [.handOffSnapshot] + settle()
                }
                return settle()
            }

        case .tick(let time):
            guard let d = deadline, time >= d else { return [] }
            switch phase {
            case .waitingForRead:
                if readBeforeKey { return restoreAndSettle() }
                // ⌘V went out but nobody read our text: it did not land anywhere.
                return enterCard(.pasteNotRead)
            case .settling:
                return restoreAndSettle()
            case .waitingForField:
                return [.disarmFieldWatch] + settle()
            default:
                return []
            }
        }
    }

    private var isCardShowing: Bool {
        switch phase {
        case .card, .waitingForField: true
        default: false
        }
    }

    private mutating func begin(text: String, start: FocusInfo?, now: FocusInfo, env: Environment, carried: Bool, time: Double) -> [Action] {
        began = time
        raw = text.trimmingWhitespace
        self.env = env
        holdsSnapshot = carried
        guard !raw.isEmpty else {
            outcome = .empty
            // A carried snapshot still has to go back before this insertion can settle.
            if holdsSnapshot { return [.dispatched(.empty)] + restoreAndSettle() }
            return [.dispatched(.empty)] + settle()
        }
        if !config.allowAcrossAppSwitch, let was = start?.pid, let isNow = now.pid, was != isNow {
            return enterCard(.appChanged)
        }
        switch now.kind {
        case .secureText: return enterCard(.secureField)
        case .notText: return enterCard(.noTextField)
        case .editableText, .unknown: return route(to: now)
        }
    }

    /// Picks paste or accessibility for `focus`.
    private mutating func route(to focus: FocusInfo) -> [Action] {
        target = focus
        text = SmartSpacing.apply(raw, caret: focus.caret, trailingSpace: config.trailingSpace)
        if config.preferAccessibility, focus.allowsAccessibilityInsert { return enterAccessibility() }
        guard env.canPostKeys else {
            return focus.allowsAccessibilityInsert ? enterAccessibility() : enterCard(.cannotPostKeys)
        }
        if holdsSnapshot {
            phase = .writing
            return [.writeTransient(text)]
        }
        if copiedForCard, env.clipboard != .allowed {
            // The clipboard already holds this text for the user and can't be snapshotted: paste
            // it without a restore, which leaves the same text there.
            phase = .writing
            return [.writeTransient(text)]
        }
        if env.clipboard == .allowed {
            phase = .snapshotting
            return [.snapshotClipboard]
        }
        if focus.allowsAccessibilityInsert { return enterAccessibility() }
        if config.unreadableClipboard == .pasteWithoutRestore {
            phase = .writing
            return [.writeTransient(text)]
        }
        return enterCard(.clipboardUnavailable)
    }

    /// The paste path failed before ⌘V: try accessibility, else the card.
    private mutating func fallback(_ reason: CardReason) -> [Action] {
        if let target, target.allowsAccessibilityInsert { return enterAccessibility() }
        return enterCard(reason)
    }

    private mutating func enterAccessibility() -> [Action] {
        guard let target else { return enterCard(.accessibilityInsertFailed) }
        phase = .accessibility
        return restoreIfHeld() + [.insertViaAccessibility(text, target)]
    }

    private mutating func enterCard(_ reason: CardReason) -> [Action] {
        let restore = restoreIfHeld()
        phase = .card(reason)
        if !viaCard { outcome = .card(reason) }
        var copy: [Action] = []
        if config.copyWhenNoField, !viaCard, reason == .noTextField || reason == .appChanged {
            // After the restore, so the user's own clipboard never comes back over the text.
            copiedForCard = true
            clipboard = .copiedForCard
            copy = [.copyToClipboard(raw)]
        }
        return restore + copy + [.showCard(raw, reason), .dispatched(.card(reason))]
    }

    /// Our text may be on the clipboard on the way out of the paste path: put the user's back.
    private mutating func restoreIfHeld() -> [Action] {
        guard holdsSnapshot else { return [] }
        holdsSnapshot = false  // `.restored` records the result
        return [.restoreClipboard]
    }

    private mutating func restoreAndSettle() -> [Action] {
        guard holdsSnapshot else { return settle() }
        holdsSnapshot = false
        phase = .restoring
        return [.restoreClipboard]
    }

    private mutating func externalChange() -> [Action] {
        holdsSnapshot = false
        clipboard = .leftExternalChange
        return [.dropSnapshot] + settle()
    }

    private mutating func settle() -> [Action] {
        phase = .done
        func ms(_ t: Double?) -> Double? { t.map { ($0 - began) * 1000 } }
        return [.settled(Settlement(
            outcome: outcome, readConfirmed: firstReadAt != nil, keyMs: ms(keyAt), firstReadMs: ms(firstReadAt),
            restoreMs: ms(restoredAt), clipboard: clipboard, viaCard: viaCard))]
    }
}

extension String {
    var trimmingWhitespace: String {
        var s = Substring(self)
        while let c = s.first, c.isWhitespace { s = s.dropFirst() }
        while let c = s.last, c.isWhitespace { s = s.dropLast() }
        return String(s)
    }
}
