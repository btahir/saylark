import AppKit
import Observation
import SaylarkCore

/// The Dictionary tab's data: the entries of `dictionary.txt`, filtered by the search box. Every
/// edit writes the file (the engine reloads it on its own), and an edit made elsewhere (a text
/// editor, `saylark dict`) shows up here within about a second.
@MainActor @Observable public final class DictionaryModel {
    /// The add or edit form above the list.
    public struct Editor: Equatable {
        /// The term being edited, or nil when adding a new one.
        public var original: String?
        public var term: String
        public var heardAs: String
        public var problem: String?

        public init(original: String? = nil, term: String = "", heardAs: String = "", problem: String? = nil) {
            self.original = original
            self.term = term
            self.heardAs = heardAs
            self.problem = problem
        }
    }

    public let url: URL
    public private(set) var entries: [DictionaryEntry] = []
    /// Lines in the file that were skipped.
    public private(set) var problems: [DictionaryFile.Problem] = []
    public private(set) var loaded = false
    /// The file could not be read or written.
    public private(set) var failure: String?
    public var query = ""
    public var editor: Editor?
    /// Renders only: draws this row as if the pointer were over it.
    public var hoverPreview: String?
    /// The term just removed, offered back with Undo until the next change.
    public private(set) var removed: Removal?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var removalTimeout: Task<Void, Never>?
    /// How long the "Removed … Undo" bar stays. Replaced in tests.
    @ObservationIgnored var undoWindow: Duration = .seconds(8)

    /// A removed entry and the file text on both sides of the removal, so Undo can put the line back
    /// exactly where it was (comments and order included).
    public struct Removal: Equatable {
        public var entry: DictionaryEntry
        var before: String?
        var after: String?
    }

    public init(url: URL) {
        self.url = url
    }

    /// Entries whose term or a heard-as form contains the search text.
    public var shown: [DictionaryEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { e in
            e.term.localizedCaseInsensitiveContains(q) || e.aliases.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    public var aliasCount: Int { entries.reduce(0) { $0 + $1.aliases.count } }

    /// Reads the file. A missing file is an empty dictionary.
    public func load() {
        do {
            let file = FileManager.default.fileExists(atPath: url.path) ? try DictionaryFile.load(url) : DictionaryFile.parse("")
            entries = file.entries
            problems = file.problems
            failure = nil
        } catch {
            failure = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Reloads whenever the file changes on disk.
    public func watch() {
        guard watcher == nil else { return }
        let w = FileWatcher(url: url) { [weak self] in
            Task { @MainActor in self?.load() }
        }
        w.start()
        watcher = w
    }

    public func stopWatching() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: Editing

    public func startAdding() {
        editor = Editor(term: query.trimmingCharacters(in: .whitespaces))
    }

    public func startEditing(_ entry: DictionaryEntry) {
        editor = Editor(original: entry.term, term: entry.term, heardAs: entry.aliases.joined(separator: ", "))
    }

    public func cancelEditing() { editor = nil }

    /// Saves the form. Leaves it open with a reason when the term can't be used.
    @discardableResult
    public func commit() -> Bool {
        guard var e = editor else { return false }
        let term = e.term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let why = DictionaryFile.problem(with: term) {
            e.problem = term.isEmpty ? "Type the term the way it should be written." : Self.sentence(why)
            editor = e
            return false
        }
        let aliases = e.heardAs.split(separator: ",").map(String.init)
        let original = e.original
        let saved = write { file in
            if let original {
                // An edit: the form is the whole entry, so heard-as forms can be removed too. Renaming
                // onto another term's spelling merges the two.
                var entry = DictionaryEntry(term: term, aliases: aliases)
                if SoundKey.spelling(original) != entry.id, let other = file.entry(term) {
                    entry.aliases = DictionaryEntry.clean(other.aliases + entry.aliases, term: term)
                    file.remove(other.term)
                }
                file.set(entry, replacing: original)
            } else {
                file.add(term, aliases: aliases)
            }
        }
        guard saved else { return false }
        editor = nil
        return true
    }

    /// Removes a term. It can be put back with `undoRemove()` (the Undo button or ⌘Z).
    public func remove(_ entry: DictionaryEntry) {
        let before = try? String(contentsOf: url, encoding: .utf8)
        guard write({ file in file.remove(entry.term) }) else { return }
        if editor?.original.map(SoundKey.spelling) == entry.id { editor = nil }
        removed = Removal(entry: entry, before: before, after: try? String(contentsOf: url, encoding: .utf8))
        removalTimeout?.cancel()
        let window = undoWindow
        removalTimeout = Task { [weak self] in
            try? await Task.sleep(for: window)
            guard !Task.isCancelled else { return }
            self?.removed = nil
        }
    }

    /// Puts the last removed term back. When the file is as the removal left it, the old text is
    /// restored as it was; when it changed since, the entry is added again.
    public func undoRemove() {
        guard let r = removed else { return }
        removed = nil
        removalTimeout?.cancel()
        let now = try? String(contentsOf: url, encoding: .utf8)
        if let before = r.before, now == r.after {
            do {
                try Data(before.utf8).write(to: url, options: .atomic)
                load()
                return
            } catch {}
        }
        _ = write { file in file.set(r.entry) }
    }

    /// Hides the Undo bar without undoing.
    public func dismissRemoval() {
        removalTimeout?.cancel()
        removed = nil
    }

    /// Opens the file in the user's text editor.
    public func openFile() {
        if !FileManager.default.fileExists(atPath: url.path) { _ = write { _ in } }
        NSWorkspace.shared.open(url)
    }

    public func revealFile() {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func write(_ change: (inout DictionaryFile) -> Void) -> Bool {
        do {
            try DictionaryFile.update(url) { change(&$0) }
            load()
            return true
        } catch {
            failure = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    static func sentence(_ reason: String) -> String {
        reason.prefix(1).uppercased() + reason.dropFirst() + "."
    }
}
