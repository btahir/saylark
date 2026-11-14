import Foundation
import SaylarkCore

/// Why an Active take ended where it did, next to the pill events. The pill events carry
/// everything the app shows (`PillOutcome.cannotPaste`, `PillError.modelNotReady`, `.pasteFailed`);
/// these are for tests, `saylark simulate` and logs, and keep the finer cause the pill folds away.
public enum EngineNotice: Sendable, Equatable {
    /// The trigger was pressed before the speech model was ready. Nothing was recorded.
    case modelNotReady(ModelState)
    /// A take (or `paste(_:)`) went to the card instead of the field.
    case card(take: UUID, cause: CardCause)
    /// ⌘V went out but the app never read the text. The pill shows `.pasteFailed`.
    case pasteFailed(take: UUID)
    /// Dictate and send: Return ended the take but no Return was sent to the app.
    case sendSkipped(take: UUID, why: SendSkip)
}

/// Why the text went to the card. The pill shows `.noTextField` for most and
/// `.cannotPaste(reason:)` for the two that a permission fixes.
public enum CardCause: String, Sendable, Equatable {
    /// No text field had focus.
    case noTextField
    /// A password field had focus. Saylark never pastes there.
    case secureField
    /// A different app had focus when the take ended than when it started.
    case appChanged
    /// Saylark may not post key events (Accessibility is off).
    case accessibilityOff
    /// The clipboard can't be read without the macOS prompt, so the user's contents could not be
    /// put back after a paste ("Paste from other apps" is set to ask or deny).
    case clipboardBlocked
    /// ⌘V went out but the app never read the text.
    case pasteNotRead
    case accessibilityInsertFailed

    /// The pill's reason when a permission is what stops the paste; nil for "no field" cards.
    public var pillReason: CardReason? {
        switch self {
        case .accessibilityOff: .accessibilityOff
        case .clipboardBlocked: .clipboardNotAllowed
        default: nil
        }
    }

    /// The pill outcome for a card with `text`. `copied`: the text is already on the clipboard.
    public func pillOutcome(_ text: String, copied: Bool = false) -> PillOutcome {
        if let reason = pillReason { return .cannotPaste(text, reason: reason) }
        return copied ? .noTextFieldCopied(text) : .noTextField(text)
    }
}

/// Why dictate-and-send did not press Return after the paste.
public enum SendSkip: String, Sendable, Equatable {
    /// The text went to the card (no field, or it could not be pasted).
    case card
    /// The app did not read the pasted text in time.
    case notRead
    /// Nothing was said.
    case empty
    /// Transcription failed.
    case failed
    /// Posting Return failed (the app was no longer frontmost, or no key permission).
    case postFailed
}

extension ModelState {
    /// The sentence the pill shows when the trigger is pressed before the model is ready.
    public var notReadyMessage: String {
        func pct(_ p: Double) -> Int { Int((max(0, min(1, p)) * 100).rounded()) }
        switch self {
        case .downloading(let p): return "Downloading the speech model, \(pct(p))%."
        case .compiling(let p): return "Preparing the speech model, \(pct(p))%."
        case .failed: return "The speech model didn't load. Open the menu."
        default: return "Still getting ready. Try again in a moment."
        }
    }
}
