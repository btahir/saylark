import Foundation
import SaylarkCore

/// What a Library row says about its take, and what the row offers. Pure, so the tests can read it.
public struct TakeRowState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Transcribed and saved, nothing was pasted (an old Shadow take, or one ended by a pause).
        case logged
        case inserted
        /// Pasted, then Return was pressed in the app.
        case sent
        /// No text field: shown on the card and not pasted anywhere.
        case card
        case copied
        case cancelled
        case failed
        case empty
    }

    public enum Action: Hashable, Sendable {
        case copy, pasteAgain, play
    }

    public var kind: Kind
    /// Restored from the crash spool at launch.
    public var recovered: Bool
    public var hasText: Bool
    public var hasAudio: Bool

    public init(_ r: DictationRecord) {
        hasText = !r.cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hasAudio = r.audioPath != nil
        recovered = r.recovered
        switch r.outcome {
        case .logged: kind = .logged
        case .inserted: kind = r.sent ? .sent : .inserted
        case .card: kind = .card
        case .copied: kind = .copied
        case .cancelled: kind = .cancelled
        case .failed: kind = .failed
        case .empty: kind = .empty
        }
    }

    public static func of(_ r: DictationRecord) -> TakeRowState { TakeRowState(r) }

    /// The quiet word under the text, or nil for the ordinary case (text went in).
    public var label: String? {
        switch kind {
        case .sent: "Sent"
        case .card: "Not pasted"
        case .copied: "Copied from the card"
        case .cancelled: "Cancelled"
        case .failed: "Couldn't transcribe"
        case .logged, .inserted, .empty: nil
        }
    }

    public var labelSymbol: String? {
        switch kind {
        case .sent: "return"
        case .card, .copied: "doc.on.clipboard"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.circle"
        default: nil
        }
    }

    /// A cancelled take can be pasted after all ("Recover").
    public var canRecover: Bool { kind == .cancelled && (hasText || hasAudio) }
    /// A failed take keeps its audio and can be transcribed again.
    public var canTranscribeAgain: Bool { kind == .failed && hasAudio }

    /// Text to show when the take has none.
    public var placeholder: String? {
        guard !hasText else { return nil }
        switch kind {
        case .failed: return "This take could not be transcribed. The audio is saved."
        case .cancelled: return hasAudio ? "Cancelled. The audio is saved." : "Cancelled."
        case .empty: return "Nothing was said."
        default: return nil
        }
    }

    /// Buttons that appear when the pointer is over the row.
    public var hoverActions: [Action] {
        var out: [Action] = []
        if hasText { out.append(.copy) }
        if hasText, kind != .cancelled, kind != .failed { out.append(.pasteAgain) }
        if hasAudio { out.append(.play) }
        return out
    }
}
