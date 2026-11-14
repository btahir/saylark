import Foundation
import QuartzCore
import SaylarkCore
import Synchronization

/// In-memory history for the fake engine, renders and tests.
public final class FakeHistory: HistoryReading {
    private let records: Mutex<[DictationRecord]>

    public init(_ records: [DictationRecord] = SampleTakes.records()) {
        self.records = Mutex(records.sorted { $0.startedAt > $1.startedAt })
    }

    public func recent(limit: Int, before: Date?) async throws -> [DictationRecord] {
        records.withLock { all in Array(all.filter { before == nil || $0.startedAt < before! }.prefix(limit)) }
    }

    public func search(_ query: String, limit: Int) async throws -> [DictationRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return try await recent(limit: limit, before: nil) }
        return records.withLock { all in
            Array(all.filter { $0.cleanText.localizedCaseInsensitiveContains(q) }.prefix(limit))
        }
    }

    /// The fake keeps no audio.
    public func audioURL(for record: DictationRecord) -> URL? { nil }

    public func delete(_ id: UUID) async throws {
        records.withLock { $0.removeAll { $0.id == id } }
    }

    /// Adds or replaces a record (what the real engine does when it saves a take).
    public func upsert(_ record: DictationRecord) {
        records.withLock { all in
            all.removeAll { $0.id == record.id }
            all.append(record)
            all.sort { $0.startedAt > $1.startedAt }
        }
    }
}

/// How a fake take ends, so every pill state and Library row state can be driven.
public enum FakeTakeEnding: Sendable, Equatable {
    /// Follows `FakeEngine.readiness`: a card for a missing permission, otherwise inserted.
    case auto
    case logged, inserted, sent
    /// No text field had focus.
    case noField
    case noAccessibility, clipboardOff
    case cancelled
    case failed
}

/// A stand-in for the real engine: no mic, no Fn hook, no model. It replays recorded voice envelopes
/// (from data/envelopes, or synthesised from the sample takes) as live events, so the pill, the menu
/// and the Library run end to end before the engine lands. `SaylarkApp --fake-engine`.
@MainActor public final class FakeEngine: DictationEngine {
    public let events: AsyncStream<DictationEvent>
    public var history: any HistoryReading { store }
    public let store: FakeHistory
    private let continuation: AsyncStream<DictationEvent>.Continuation
    private var envelopes: [VoiceEnvelope]
    private var take: Task<Void, Never>?
    private var finishRequested = false
    private var cancelRequested = false
    private var takeIndex = 0
    public private(set) var running = false

    // Pasting
    /// What `activeReadiness()` reports. Set a field to render each problem.
    public var readiness = ActiveReadiness()
    /// What the clipboard prompt ends as when `requestClipboardAccess()` is called.
    public var clipboardAnswer: ClipboardAccess = .allowed
    /// Seconds before a "paste when I click a field" wait sees a field get focus.
    public var fieldFocusDelay = 1.5
    /// The take whose card is on screen.
    private var cardRecord: DictationRecord?
    private var waiting: Task<Void, Never>?
    /// Every card and paste call, in order, for tests.
    public private(set) var calls: [String] = []

    public init(history: FakeHistory = FakeHistory(), envelopes: [VoiceEnvelope] = []) {
        store = history
        self.envelopes = envelopes
        (events, continuation) = AsyncStream.makeStream(of: DictationEvent.self, bufferingPolicy: .unbounded)
    }

    public func start() async throws { running = true }

    public func stop() {
        running = false
        cancelTake()
    }

    public func activeReadiness() -> ActiveReadiness { readiness }

    public func requestClipboardAccess() async -> ClipboardAccess {
        calls.append("requestClipboardAccess")
        readiness.clipboard = clipboardAnswer
        return clipboardAnswer
    }

    public func cardCopy() {
        calls.append("cardCopy")
        guard var record = cardRecord else { return }
        record.outcome = .copied
        cardRecord = nil
        waiting?.cancel()
        store.upsert(record)
        continuation.yield(.pill(.copied))
        continuation.yield(.saved(record))
    }

    public func cardPasteWhenField() {
        calls.append("cardPasteWhenField")
        guard var record = cardRecord else { return }
        let send = continuation
        waiting = Task { [weak self] in
            guard let delay = self?.fieldFocusDelay else { return }
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            record.outcome = .inserted
            self.cardRecord = nil
            self.store.upsert(record)
            send.yield(.pill(.fieldFocused))
            send.yield(.saved(record))
        }
    }

    public func cardDismiss() {
        calls.append("cardDismiss")
        waiting?.cancel()
        cardRecord = nil
        continuation.yield(.pill(.dismiss))
    }

    @discardableResult
    public func paste(_ id: UUID) async -> DictationOutcome {
        calls.append("paste")
        guard var record = (try? await store.recent(limit: 5000, before: nil))?.first(where: { $0.id == id }),
              !record.cleanText.isEmpty else { return .empty }
        guard readiness.canPaste else { return .card }
        record.outcome = .inserted
        store.upsert(record)
        continuation.yield(.saved(record))
        return .inserted
    }

    public func retranscribe(_ id: UUID) async throws -> DictationRecord {
        calls.append("retranscribe")
        guard var record = (try? await store.recent(limit: 5000, before: nil))?.first(where: { $0.id == id }) else {
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(250))
        let sample = SampleTakes.records()[1]
        record.rawText = sample.cleanText
        record.cleanText = sample.cleanText
        record.words = sample.words
        record.outcome = .card
        store.upsert(record)
        continuation.yield(.saved(record))
        return record
    }

    public func finishTake() { finishRequested = true }
    public func cancelTake() { cancelRequested = true }

    private func resolve(_ ending: FakeTakeEnding, cancelled: Bool) -> FakeTakeEnding {
        if cancelled { return .cancelled }
        guard ending == .auto else { return ending }
        if !readiness.accessibility { return .noAccessibility }
        if readiness.clipboard != .allowed { return .clipboardOff }
        return .inserted
    }

    /// Finishes a take the way the real engine does: the pill event, then the saved record.
    private func end(_ ending: FakeTakeEnding, record: inout DictationRecord, send: AsyncStream<DictationEvent>.Continuation) {
        let text = record.cleanText
        switch ending {
        case .auto, .logged:
            record.outcome = .logged
            send.yield(.pill(.finish(.inserted)))
        case .inserted, .sent:
            record.outcome = .inserted
            record.sent = ending == .sent
            send.yield(.pill(.finish(.inserted)))
        case .noField:
            // Like the real engine: the text goes on the (pretend) clipboard and the card says so.
            record.outcome = .copied
            cardRecord = record
            send.yield(.pill(.finish(.noTextFieldCopied(text))))
        case .noAccessibility, .clipboardOff:
            record.outcome = .card
            cardRecord = record
            let reason: CardReason = ending == .noAccessibility ? .accessibilityOff : .clipboardNotAllowed
            send.yield(.pill(.finish(.cannotPaste(text, reason: reason))))
        case .cancelled:
            // Cancelled takes are still transcribed in the background, so they keep their text.
            record.outcome = .cancelled
            send.yield(.pill(.cancel))
        case .failed:
            record.outcome = .failed
            record.rawText = ""; record.cleanText = ""; record.words = []
            send.yield(.pill(.fail(.transcriptionFailed)))
        }
        store.upsert(record)
        send.yield(.saved(record))
    }

    /// Plays one fake take in real time: listen, levels at 120 Hz, live words, then finish and save.
    /// Hands-free takes run until `finishTake()` (the pill's stop button) or 20 s.
    public func playTake(handsFree: Bool = false, ending: FakeTakeEnding = .auto) {
        guard take == nil else { return }
        let sample = SampleTakes.records()[takeIndex % 4]
        takeIndex += 1
        let env = envelopes.isEmpty ? nil : envelopes[takeIndex % envelopes.count]
        let rate = 120.0
        let levels: [Float] = env?.rms ?? SampleTakes.envelope(for: sample).map { $0 * 0.08 }
        let duration = handsFree ? 20 : Double(levels.count) / rate
        // Words: real word timings from the sample, spread over the replayed clip.
        let words = sample.words
        let span = max(0.1, words.last?.end ?? 1)
        let clipSeconds = Double(levels.count) / rate
        finishRequested = false
        cancelRequested = false
        let send = continuation
        take = Task { [weak self] in
            send.yield(.pill(.listen))
            if handsFree {
                try? await Task.sleep(for: .milliseconds(300))
                send.yield(.pill(.lockHandsFree))
            }
            let start = CACurrentMediaTime()
            var shown = 0
            var outcome: DictationOutcome = .logged
            while true {
                let t = CACurrentMediaTime() - start
                guard let self else { return }
                if self.cancelRequested { outcome = .cancelled; break }
                if self.finishRequested || t >= duration { break }
                let i = Int(t * rate) % max(1, levels.count)
                let rms = levels.isEmpty ? 0 : levels[i]
                let peak = env?.peak[i] ?? rms * 1.6
                send.yield(.level(VoiceLevel(time: t, peakDB: Float(peak.dBFS), rmsDB: Float(rms.dBFS))))
                // Each word shows a short recognition delay after its share of the clip has played.
                let due = words.prefix { $0.end / span * clipSeconds + 0.35 <= t }.count
                if due > shown {
                    shown = due
                    send.yield(.pill(.words(words.prefix(due).map(\.text))))
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
            let elapsed = CACurrentMediaTime() - start
            guard let self else { return }
            var record = sample
            record.id = UUID()
            record.startedAt = Date().addingTimeInterval(-elapsed)
            record.duration = elapsed
            record.handsFree = handsFree
            record.mode = .active
            let resolved = self.resolve(ending, cancelled: outcome == .cancelled)
            self.end(resolved, record: &record, send: send)
            self.take = nil
        }
    }
}
