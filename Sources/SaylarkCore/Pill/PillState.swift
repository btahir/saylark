import Foundation

/// What the pill shows. Pure data: the UI turns it into layers, the lab and tests drive it with events.
///
/// The pill does not know about Fn presses. The gesture state machine decides what a press means and
/// sends one of the semantic `PillEvent`s below.
public struct PillState: Sendable, Equatable {
    public var phase: PillPhase = .hidden
    /// When the current phase began (seconds, same clock as the events).
    public var phaseStart: Double = 0
    /// Hold-to-talk or hands-free. Only meaningful while listening.
    public var mode: ListenMode = .hold
    /// When the take began, for the hands-free timer.
    public var takeStart: Double = 0
    /// The last few words heard, when live words are on.
    public var words: [String] = []
    /// Words heard so far in this take. `words` holds the newest of them.
    public var wordCount = 0
    /// The mic has delivered nothing above the noise floor for `PillConfig.noSignalAfter` seconds.
    public var noSignal = false
    /// The pointer is over the pill. Keeps the card and error notices open.
    public var hovering = false
    /// Why the card could not paste, when that is the reason it is on screen. Nil when the card is
    /// there only because no text field had focus.
    public internal(set) var cardReason: CardReason?
    /// The card's text is already on the clipboard (no text field had focus, so Saylark copied it).
    /// The card says so instead of offering Copy.
    public internal(set) var cardCopied = false

    /// Last time the mic heard anything above the noise floor.
    var lastHeard: Double = 0
    /// When the hover ended, so the card's timeout restarts from there.
    var hoverEnded: Double = 0
    /// The take the pill is showing (set by `.listen` with a take ID). Events from other takes are
    /// ignored.
    public internal(set) var take: UUID?

    public init() {}

    public var isVisible: Bool { phase != .hidden }

    /// Seconds shown on the hands-free timer.
    public func elapsed(at time: Double) -> Double { max(0, time - takeStart) }
}

/// The pill's states, from PLAN §2.2.
public enum PillPhase: Sendable, Equatable {
    case hidden
    case listening
    /// Text landed in the field; the pill collapses and vanishes.
    case done
    /// The text did not go into a field. The card shows it with paste on the next field that gets
    /// focus and Dismiss, plus Copy unless it is already on the clipboard (`PillState.cardCopied`).
    case card(text: String)
    /// Copy was chosen on the card. A short "Copied", then the pill goes away.
    case copied
    /// "Paste when I click a field" was chosen; waiting for a text field to get focus.
    case waitingForField(text: String)
    /// Esc during a take. Shake, then gone.
    case cancelled
    case error(PillError)

    public var name: String {
        switch self {
        case .hidden: "hidden"
        case .listening: "listening"
        case .done: "done"
        case .card: "card"
        case .copied: "copied"
        case .waitingForField: "waiting"
        case .cancelled: "cancelled"
        case .error: "error"
        }
    }
}

public enum ListenMode: Sendable, Equatable {
    case hold
    case handsFree
}

/// How a take ended.
public enum PillOutcome: Sendable, Equatable {
    /// The text was pasted into the focused field.
    case inserted
    /// No text field had focus: show the card with this text and a Copy button.
    case noTextField(String)
    /// No text field had focus and the text is already on the clipboard: the card says "Copied"
    /// and offers paste on the next field and Dismiss.
    case noTextFieldCopied(String)
    /// Pasting is not possible right now (see `CardReason`): show the card with this text, the
    /// reason and the button that fixes it.
    case cannotPaste(String, reason: CardReason)
    /// Nothing was said. The pill just goes away.
    case empty
}

/// Why a card could not paste. The card shows the sentence and one button above its actions.
public enum CardReason: Sendable, Equatable {
    /// Accessibility is off, so Saylark cannot press Command V or see the focused field.
    case accessibilityOff
    /// macOS has not let Saylark read the clipboard, so it cannot put the user's own clipboard back.
    case clipboardNotAllowed

    public var sentence: String {
        switch self {
        case .accessibilityOff: "Accessibility is off, so Saylark can't paste."
        case .clipboardNotAllowed: "Clipboard access is off, so Saylark can't paste."
        }
    }

    public var actionTitle: String {
        switch self {
        case .accessibilityOff: "Open Settings"
        case .clipboardNotAllowed: "Allow"
        }
    }
}

/// Errors the pill can explain in one sentence with at most one action.
public enum PillError: Sendable, Equatable {
    case microphoneAccessOff
    case microphoneMissing(name: String)
    case accessibilityOff
    /// Speech recognition failed for the take. Its audio is saved in the Library.
    case transcriptionFailed
    /// The trigger key was pressed before Saylark could take it (model loading, permission missing).
    /// The engine sends the sentence ("Downloading the speech model, 42%.").
    case modelNotReady(message: String)
    /// macOS has not let Saylark read the clipboard, so a paste would lose the user's clipboard.
    case clipboardAccessOff
    /// The paste did not go through. The text is saved in the Library.
    case pasteFailed

    public var message: String {
        switch self {
        case .microphoneAccessOff: "Microphone access is off."
        case .microphoneMissing(let name): "The \(name) is unplugged."
        case .accessibilityOff: "Saylark can't paste yet."
        case .transcriptionFailed: "Couldn't transcribe. Audio is saved."
        case .modelNotReady(let message): message
        case .clipboardAccessOff: "Can't paste. Clipboard access is off."
        case .pasteFailed: "Couldn't paste. It's in the Library."
        }
    }

    /// The one button, or nil when the notice only has a close button.
    public var actionTitle: String? {
        switch self {
        case .microphoneAccessOff, .accessibilityOff: "Open Settings"
        case .microphoneMissing: "Use Built-in Mic"
        case .transcriptionFailed: "OK"
        case .modelNotReady: nil
        case .clipboardAccessOff: "Allow"
        case .pasteFailed: "Open Library"
        }
    }

    /// SF Symbol shown before the sentence, or nil for none.
    public var symbol: String? {
        switch self {
        case .microphoneAccessOff, .microphoneMissing: "mic.slash"
        case .accessibilityOff: "lock"
        case .transcriptionFailed: "waveform"
        case .modelNotReady: nil
        case .clipboardAccessOff: "doc.on.clipboard"
        case .pasteFailed: "exclamationmark.circle"
        }
    }
}

/// Semantic events from the gesture machine, the engine and the pill's own buttons.
public enum PillEvent: Sendable, Equatable {
    /// A take starts (Fn held). Also interrupts a dismissal that is still animating.
    case listen
    /// Double-tap: the take locks into hands-free.
    case lockHandsFree
    /// Fn released (hold) or the stop button clicked (hands-free).
    case finish(PillOutcome)
    /// Esc during a take.
    case cancel
    /// Every live word so far in this take. The machine keeps the newest `maxWords`.
    case words([String])
    case fail(PillError)
    /// Card button: paste on the next text field that gets focus.
    case pasteWhenFocused
    /// Card button: Copy. The pill shows "Copied" for a moment, then goes away.
    case copied
    /// Card or notice closed.
    case dismiss
    /// A text field got focus while waiting: the text went in.
    case fieldFocused
    case hover(Bool)
}

/// Timings. Defaults follow PLAN §2.2.
public struct PillConfig: Sendable, Equatable {
    /// Silence this long (from the start of the take or the last sound) counts as no signal.
    public var noSignalAfter: Double = 2.0
    /// Peak level, in dBFS, that counts as "heard something". A live mic's room tone (about -70 to
    /// -55 dBFS peak on the eval clips) sits above this; a muted or dead input sits far below it.
    public var noSignalFloorDB: Double = -80
    /// How long `.done` lasts before `.hidden` (the collapse animation).
    public var doneHold: Double = 0.25
    /// How long `.cancelled` lasts (the shake).
    public var cancelHold: Double = 0.5
    /// The card closes by itself after this long without hover.
    public var cardTimeout: Double = 8
    /// How long "Copied" stays after Copy on the card.
    public var copiedHold: Double = 1.1
    public var errorTimeout: Double = 6
    /// Live words kept on the pill.
    public var maxWords: Int = 12
    /// Shown in the no-signal hint, e.g. "USB mic".
    public var micName: String = "microphone"

    public init() {}
}
