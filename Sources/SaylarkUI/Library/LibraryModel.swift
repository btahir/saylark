import AppKit
import Observation
import SaylarkCore

/// The Library's data: takes from history, grouped by day, filtered by the search box.
@MainActor @Observable public final class LibraryModel {
    public struct Day: Identifiable {
        public var id: Date { start }
        public let start: Date
        public let title: String
        public let records: [DictationRecord]
    }

    @ObservationIgnored let history: any HistoryReading
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var statsTask: Task<Void, Never>?
    @ObservationIgnored var now: () -> Date = Date.init

    /// Everything loaded, newest first (feeds the stats).
    public private(set) var all: [DictationRecord] = []
    /// Search results, or nil when the search box is empty.
    public private(set) var results: [DictationRecord]?
    public private(set) var stats = LibraryStats()
    public private(set) var loaded = false
    public var query = "" { didSet { if query != oldValue { runSearch() } } }
    /// Row whose full text and player are open.
    public var expanded: UUID?
    /// Renders only: draws this row as if the pointer were over it.
    public var hoverPreview: UUID?
    /// A take the user asked to delete, waiting for them to confirm. Deleting also removes its audio,
    /// so it is never done on one click.
    public var pendingDelete: DictationRecord?
    public let player = PlaybackModel()
    /// The engine that pastes and transcribes again. Nil in tests that only read.
    @ObservationIgnored public weak var engine: (any DictationEngine)?
    /// The trigger key's name, for the empty state.
    public var triggerName = "Fn"
    /// Takes with a paste or transcription in flight.
    public private(set) var busy: Set<UUID> = []
    /// A short result under a row ("Pasted", "No text field here"), cleared after a moment.
    public private(set) var flash: [UUID: String] = [:]
    /// Time between leaving Saylark's window and pasting, so the paste lands in the app the user was in.
    @ObservationIgnored var pasteDelay: Duration = .milliseconds(300)
    /// Hands the keyboard back to the app that was in front. Replaced in tests.
    @ObservationIgnored var yieldFocus: () -> Void = { NSApp.deactivate() }

    public init(history: any HistoryReading) {
        self.history = history
    }

    public var shown: [DictationRecord] { results ?? all }

    public var days: [Day] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: shown) { cal.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { Day(start: $0, title: Self.dayTitle($0, now: now()), records: groups[$0]!) }
    }

    /// Loads the last few thousand takes (a busy week) for the list and the stats.
    public func load() async {
        let records = (try? await history.recent(limit: 3000, before: nil)) ?? []
        all = records
        loaded = true
        refreshStats()
        await statsTask?.value
    }

    /// A take was saved or changed (a card button, a new transcription).
    public func upsert(_ record: DictationRecord) {
        all.removeAll { $0.id == record.id }
        let i = all.firstIndex { $0.startedAt < record.startedAt } ?? all.count
        all.insert(record, at: i)
        refreshStats()
        if !query.isEmpty { runSearch() }
    }

    /// Asks before deleting: the take and its audio cannot be brought back.
    public func requestDelete(_ record: DictationRecord) {
        pendingDelete = record
    }

    public func confirmDelete() {
        guard let record = pendingDelete else { return }
        pendingDelete = nil
        delete(record)
    }

    public func delete(_ record: DictationRecord) {
        if expanded == record.id { expanded = nil }
        if player.record?.id == record.id { player.stop() }
        all.removeAll { $0.id == record.id }
        results?.removeAll { $0.id == record.id }
        refreshStats()
        Task { try? await history.delete(record.id) }
    }

    /// Copies a take's text. Only ever called from the user's click on Copy.
    public func copy(_ record: DictationRecord) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(record.cleanText, forType: .string)
    }

    /// Pastes a take again at the cursor, in the app the user was in before opening the Library.
    public func pasteAgain(_ record: DictationRecord) {
        guard let engine, busy.insert(record.id).inserted else { return }
        yieldFocus()
        let delay = pasteDelay
        Task {
            try? await Task.sleep(for: delay)
            let outcome = await engine.paste(record.id)
            busy.remove(record.id)
            show(Self.message(for: outcome), for: record.id)
        }
    }

    /// Recover: paste a cancelled take (transcribing its audio first when it has no text yet).
    public func recover(_ record: DictationRecord) {
        guard let engine, busy.insert(record.id).inserted else { return }
        yieldFocus()
        let delay = pasteDelay
        Task {
            try? await Task.sleep(for: delay)
            let outcome = await TakeActions.pasteOrRecover(record, engine: engine)
            busy.remove(record.id)
            show(Self.message(for: outcome), for: record.id)
        }
    }

    /// Transcribes a failed take again from its saved audio.
    public func transcribeAgain(_ record: DictationRecord) {
        guard let engine, busy.insert(record.id).inserted else { return }
        Task {
            do {
                let updated = try await engine.retranscribe(record.id)
                busy.remove(record.id)
                upsert(updated)
            } catch {
                busy.remove(record.id)
                show("Couldn't transcribe it again", for: record.id)
            }
        }
    }

    static func message(for outcome: DictationOutcome) -> String {
        switch outcome {
        case .inserted: "Pasted"
        case .card: "No text field here"
        case .copied: "Copied"
        case .empty: "Nothing to paste"
        default: "Couldn't paste"
        }
    }

    private func show(_ text: String, for id: UUID) {
        flash[id] = text
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if flash[id] == text { flash[id] = nil }
        }
    }

    public func togglePlay(_ record: DictationRecord) {
        if player.record?.id == record.id {
            player.togglePlay()
        } else {
            expanded = record.id
            player.open(record, url: history.audioURL(for: record))
            player.play()
        }
    }

    /// Recomputes the header numbers off the main thread. A newer call replaces an older one that is
    /// still running, so a burst of saves costs one result and the pill's frames never wait on it.
    private func refreshStats() {
        statsTask?.cancel()
        let records = all, at = now()
        statsTask = Task { [weak self] in
            let computed = await Task.detached(priority: .utility) { LibraryStats.compute(records, now: at) }.value
            guard !Task.isCancelled else { return }
            self?.stats = computed
        }
    }

    /// Waits for the search and stats work in flight. Tests and renders use this instead of sleeping.
    func settle() async {
        await searchTask?.value
        await statsTask?.value
    }

    private func runSearch() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = nil; return }
        searchTask = Task { [history] in
            let found = (try? await history.search(q, limit: 500)) ?? []
            guard !Task.isCancelled else { return }
            self.results = found
        }
    }

    static func dayTitle(_ day: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate(cal.isDate(day, equalTo: now, toGranularity: .year) ? "EEEE d MMMM" : "d MMMM y")
        return f.string(from: day)
    }
}
