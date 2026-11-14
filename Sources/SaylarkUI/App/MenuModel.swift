import Foundation
import SaylarkCore

/// What the menu bar menu holds, as plain data: the controller turns it into `NSMenuItem`s, and the
/// tests read it. Everything that depends on the clock or the newest takes is decided here.
public struct MenuModel: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case copyLast
        case pasteLast
        case recover(UUID)
        /// The main window (Home, Dictionary, Settings).
        case openSaylark
        case pause
        case resume
        case openSettings
        case quit
    }

    public struct Item: Equatable, Sendable {
        public var title: String
        public var subtitle: String?
        public var action: Action?
        public var checked = false
        public var enabled = true
    }

    public enum Entry: Equatable, Sendable {
        case item(Item)
        case separator
        case submenu(title: String, items: [Item])
    }

    public var entries: [Entry]

    /// A cancelled take can be recovered for this long.
    public static let recoverWindow: TimeInterval = 24 * 3600

    /// `recent` is the takes the app has seen this session, in any order.
    public init(recent: [DictationRecord], now: Date = Date(), pausedUntil: Date? = nil,
                timeFormat: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) {
        var out: [Entry] = []
        let last = Self.lastTranscript(in: recent)
        if let last {
            out.append(.item(Item(title: "Copy Last Take", subtitle: Self.excerpt(last.cleanText), action: .copyLast)))
            out.append(.item(Item(title: "Paste Last Take", action: .pasteLast)))
        } else {
            out.append(.item(Item(title: "No takes yet", enabled: false)))
        }
        if let take = Self.recoverable(in: recent, now: now) {
            let text = take.cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(.item(Item(title: "Recover Cancelled Take",
                                  subtitle: text.isEmpty ? "Transcribes the saved audio, then pastes" : Self.excerpt(text),
                                  action: .recover(take.id))))
        }
        out.append(.separator)
        out.append(.item(Item(title: "Open Saylark", action: .openSaylark)))
        if let pausedUntil {
            out.append(.item(Item(title: "Resume", subtitle: "Paused until " + timeFormat(pausedUntil), action: .resume)))
        } else {
            out.append(.item(Item(title: "Pause for 1 Hour", action: .pause)))
        }
        out.append(.separator)
        out.append(.item(Item(title: "Settings…", action: .openSettings)))
        out.append(.item(Item(title: "Quit Saylark", action: .quit)))
        entries = out
    }

    /// The newest take with text that is not cancelled, failed or empty.
    public static func lastTranscript(in records: [DictationRecord]) -> DictationRecord? {
        records.filter { r in
            switch r.outcome {
            case .logged, .inserted, .copied, .card: !r.cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .cancelled, .empty, .failed: false
            }
        }.max { $0.startedAt < $1.startedAt }
    }

    /// The newest take, when it was cancelled less than 24 hours ago and has text or audio.
    public static func recoverable(in records: [DictationRecord], now: Date) -> DictationRecord? {
        guard let newest = records.max(by: { $0.startedAt < $1.startedAt }), newest.outcome == .cancelled,
              now.timeIntervalSince(newest.startedAt) <= recoverWindow,
              !newest.cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newest.audioPath != nil
        else { return nil }
        return newest
    }

    public static func excerpt(_ text: String, limit: Int = 42) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The glyph for what Saylark is doing now. A running take wins, then a pause, then a problem.
    @MainActor public static func glyph(listening: Bool, paused: Bool, problem: Bool) -> MenuBarGlyph.State {
        if listening { return .listening }
        if paused { return .paused }
        return problem ? .problem : .idle
    }
}

/// Paste a past take, or recover one that has no text yet (cancelled before it was transcribed).
@MainActor public enum TakeActions {
    @discardableResult
    public static func pasteOrRecover(_ record: DictationRecord, engine: any DictationEngine) async -> DictationOutcome {
        var id = record.id
        if record.cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let updated = try? await engine.retranscribe(record.id) else { return .failed }
            id = updated.id
        }
        return await engine.paste(id)
    }
}
