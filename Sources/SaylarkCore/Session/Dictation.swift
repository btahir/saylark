import Foundation

// The boundary between the engine (hotkey, capture, transcription, storage) and the app's UI.
// The engine implements `DictationEngine` and `HistoryReading`; the UI only talks to these types,
// so it can be built and tested against a fake engine.

/// How a take was made, as stored in history. Saylark always pastes now (`active`); `shadow` is
/// kept only so takes from the removed Shadow mode (listen next to another app, never paste)
/// still read back.
public enum DictationMode: String, Codable, Sendable, CaseIterable {
    case shadow
    case active
}

/// One mic level reading, about 120 per second while a take is running.
public struct VoiceLevel: Sendable, Equatable {
    /// Seconds since the take started.
    public var time: Double
    public var peakDB: Float
    public var rmsDB: Float

    public init(time: Double, peakDB: Float, rmsDB: Float) {
        self.time = time
        self.peakDB = peakDB
        self.rmsDB = rmsDB
    }
}

/// What the engine tells the UI. Pill events drive the pill; levels drive the voice visual.
public enum DictationEvent: Sendable, Equatable {
    /// `take` is the take the event belongs to (nil for events not tied to a take, e.g. from the
    /// pill's own buttons). The pill ignores events from a take that is not the current one, so a
    /// slow finish from one take can never close the next take's pill.
    case pill(PillEvent, take: UUID? = nil)
    case level(VoiceLevel)
    /// A take was saved to history (also sent when a record changes, e.g. a card button).
    case saved(DictationRecord)
}

/// Which key starts a take. Fn is the default; the right-hand modifiers cover keyboards with no Fn
/// key, or a Mac where another app already listens to Fn.
public enum TriggerKey: String, Codable, Sendable, CaseIterable {
    case fn
    case rightOption
    case rightCommand
}

/// Return during a take: stop, paste, then press Return in the app (dictate and send in one gesture).
public enum SendOnReturn: String, Codable, Sendable, CaseIterable {
    case off
    /// Only in the apps listed under `DictationSettingsKey.sendOnReturnApps`.
    case listedApps
    case everywhere
}

/// UserDefaults keys the engine and the app both read. Values are the raw values of the enums above.
public enum DictationSettingsKey {
    public static let triggerKey = "triggerKey"
    public static let sendOnReturn = "sendOnReturn"
    /// [String] of bundle IDs. Missing key means `defaultSendOnReturnApps`.
    public static let sendOnReturnApps = "sendOnReturnApps"
    /// Bool, default true: a long pause inside a long take becomes a paragraph break.
    public static let paragraphsFromPauses = "paragraphsFromPauses"
    /// Bool, default true: with no text field, the take's text goes on the clipboard (and stays)
    /// and the card says "Copied".
    public static let copyWhenNoField = "copyWhenNoField"

    /// AI agent apps, where the owner's data shows messages are sent word for word about a second
    /// after the take ends. Browsers are left out on purpose: the same browser holds agent chats and
    /// posts that get edited before sending.
    public static let defaultSendOnReturnApps = [
        "com.anthropic.claudefordesktop",
        "com.openai.codex",
        "com.openai.chat",
    ]
}

/// Whether Saylark may read the clipboard (needed to put the user's own contents back after a paste).
public enum ClipboardAccess: String, Sendable, Equatable {
    case allowed
    /// macOS would show its "paste from other apps" prompt on the next read.
    case wouldAsk
    case denied
}

/// What Saylark still needs before it can paste. The UI shows one plain sentence per problem.
public struct ActiveReadiness: Sendable, Equatable {
    public var accessibility: Bool
    public var clipboard: ClipboardAccess
    /// Another dictation app that is running and listens to the same trigger key (e.g. "Wispr Flow"):
    /// both would paste. Nil when there is no clash.
    public var triggerClash: String?

    public init(accessibility: Bool = true, clipboard: ClipboardAccess = .allowed, triggerClash: String? = nil) {
        self.accessibility = accessibility
        self.clipboard = clipboard
        self.triggerClash = triggerClash
    }

    public var canPaste: Bool { accessibility && clipboard == .allowed }
}

/// How a take ended.
public enum DictationOutcome: String, Codable, Sendable {
    /// Transcribed and saved, nothing pasted: a take finished while Saylark stopped, or a take
    /// from the removed Shadow mode.
    case logged
    case inserted
    /// The text went on the clipboard: no text field had focus (copied automatically), or the user
    /// pressed Copy on the card.
    case copied
    /// No text field: the text was shown on the card and has not gone anywhere yet.
    case card
    case cancelled
    /// Nothing was said.
    case empty
    /// Transcription failed. The audio is kept so the take can be transcribed again later.
    case failed
}

/// One take, as stored in history.
public struct DictationRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var startedAt: Date
    /// Seconds of audio.
    public var duration: Double
    public var mode: DictationMode
    public var handsFree: Bool
    public var appBundleID: String?
    public var appName: String?
    public var rawText: String
    public var cleanText: String
    public var words: [TranscriptWord]
    /// Fn released (or stop clicked) → final text ready, in milliseconds.
    public var releaseToTextMs: Double?
    public var outcome: DictationOutcome
    /// Audio file path relative to the history folder, if audio was kept.
    public var audioPath: String?
    /// Recovered from the crash spool at launch (the app quit or crashed during the take).
    public var recovered: Bool
    /// Return was pressed after the paste (dictate and send).
    public var sent: Bool = false

    public init(
        id: UUID = UUID(), startedAt: Date, duration: Double, mode: DictationMode, handsFree: Bool,
        appBundleID: String? = nil, appName: String? = nil, rawText: String, cleanText: String,
        words: [TranscriptWord] = [], releaseToTextMs: Double? = nil, outcome: DictationOutcome,
        audioPath: String? = nil, recovered: Bool = false
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.mode = mode
        self.handsFree = handsFree
        self.appBundleID = appBundleID
        self.appName = appName
        self.rawText = rawText
        self.cleanText = cleanText
        self.words = words
        self.releaseToTextMs = releaseToTextMs
        self.outcome = outcome
        self.audioPath = audioPath
        self.recovered = recovered
    }

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, duration, mode, handsFree, appBundleID, appName, rawText, cleanText, words
        case releaseToTextMs, outcome, audioPath, recovered, sent
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        duration = try c.decode(Double.self, forKey: .duration)
        mode = try c.decode(DictationMode.self, forKey: .mode)
        handsFree = try c.decode(Bool.self, forKey: .handsFree)
        appBundleID = try c.decodeIfPresent(String.self, forKey: .appBundleID)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        rawText = try c.decode(String.self, forKey: .rawText)
        cleanText = try c.decode(String.self, forKey: .cleanText)
        words = try c.decodeIfPresent([TranscriptWord].self, forKey: .words) ?? []
        releaseToTextMs = try c.decodeIfPresent(Double.self, forKey: .releaseToTextMs)
        outcome = try c.decode(DictationOutcome.self, forKey: .outcome)
        audioPath = try c.decodeIfPresent(String.self, forKey: .audioPath)
        // Older records have no `recovered` key.
        recovered = try c.decodeIfPresent(Bool.self, forKey: .recovered) ?? false
        sent = try c.decodeIfPresent(Bool.self, forKey: .sent) ?? false
    }
}

/// Read access to history for the Library window.
public protocol HistoryReading: Sendable {
    /// Newest first.
    func recent(limit: Int, before: Date?) async throws -> [DictationRecord]
    /// Full-text search over the clean text, newest first.
    func search(_ query: String, limit: Int) async throws -> [DictationRecord]
    /// Absolute URL of a record's audio, if it was kept.
    func audioURL(for record: DictationRecord) -> URL?
    func delete(_ id: UUID) async throws
}

/// The speech model's readiness, for onboarding ("Getting ready…" with progress). The first launch
/// downloads about 600 MB and compiles for the Neural Engine (about 16–30 s); later launches load
/// from cache in well under a second.
public enum ModelState: Sendable, Equatable {
    case notLoaded
    /// 0...1.
    case downloading(progress: Double)
    /// Core ML compile for the Neural Engine. 0...1 (coarse: per model file).
    case compiling(progress: Double)
    /// Loaded; running one warm-up pass.
    case warming
    case ready
    case failed(String)
}

/// What the app needs from the engine. Implemented on the main actor; heavy work runs elsewhere.
@MainActor
public protocol DictationEngine: AnyObject {
    /// Events for the pill and the Library. One consumer.
    var events: AsyncStream<DictationEvent> { get }
    var history: any HistoryReading { get }
    /// Loads the model, installs the listen-only Fn hook and gets ready. Never prompts for
    /// permissions; throws if one is missing.
    func start() async throws
    func stop()
    /// From the pill: stop button (hands-free) or Esc.
    func finishTake()
    func cancelTake()
    /// Model readiness. Each call returns a new stream that starts with the current state.
    /// Added in M1; the default (for fakes) reports `.ready` at once.
    func modelStates() -> AsyncStream<ModelState>

    // Pasting. Defaults below do nothing, so fakes still compile.

    /// What Saylark still needs before it can paste. Cheap; never prompts.
    func activeReadiness() -> ActiveReadiness
    /// Reads the clipboard once on purpose so macOS shows its prompt, then reports the new state.
    func requestClipboardAccess() async -> ClipboardAccess
    /// Card buttons. `cardCopy` and the card itself (no text field, `copyWhenNoField`) are the only
    /// paths that overwrite the clipboard and leave it.
    func cardCopy()
    func cardPasteWhenField()
    func cardDismiss()
    /// Pastes a past take's text at the cursor now (menu "Paste last", Library "Paste again",
    /// recovering a cancelled take). Returns how it ended.
    @discardableResult func paste(_ id: UUID) async -> DictationOutcome
    /// Transcribes a take again from its saved audio (failed takes, or cancelled ones whose
    /// background transcription has not finished). Returns the updated record.
    func retranscribe(_ id: UUID) async throws -> DictationRecord
}

public extension DictationEngine {
    func activeReadiness() -> ActiveReadiness { ActiveReadiness() }
    func requestClipboardAccess() async -> ClipboardAccess { .allowed }
    func cardCopy() {}
    func cardPasteWhenField() {}
    func cardDismiss() {}
    @discardableResult func paste(_ id: UUID) async -> DictationOutcome { .empty }
    func retranscribe(_ id: UUID) async throws -> DictationRecord { throw CancellationError() }

    func modelStates() -> AsyncStream<ModelState> {
        AsyncStream { c in
            c.yield(.ready)
            c.finish()
        }
    }
}
