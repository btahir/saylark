import Foundation
import SaylarkCore
import SaylarkEngine

/// `saylark dict`: the user's dictionary file, the same one the app watches.
///
/// ```
/// saylark dict list
/// saylark dict add ShipTiffin --as "ship tiffin,shift tiffin"
/// saylark dict remove ShipTiffin
/// saylark dict path
/// saylark dict import --from vocabulary.sqlite      # add the live terms of an old store
/// ```
/// `--file PATH` works on another file instead of `~/Library/Application Support/Saylark/dictionary.txt`.
enum DictCommand {
    static func run(_ args: Arguments) throws {
        let url = args.value("file").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? DictionaryFile.defaultURL
        let sub = args.positional.first ?? "list"
        let rest = args.positional.dropFirst().joined(separator: " ")
        switch sub {
        case "list": try list(url)
        case "path": print(url.path)
        case "add":
            guard !rest.isEmpty else { throw CLIError("usage: saylark dict add <term> [--as alias,alias]") }
            if let why = DictionaryFile.problem(with: rest) { throw CLIError("can't add \"\(rest)\": \(why)") }
            let aliases = args.value("as").map { $0.split(separator: ",").map(String.init) } ?? []
            let entry = try DictionaryFile.update(url) { $0.add(rest, aliases: aliases) }
            print("added  \(entry.line)")
        case "remove", "rm":
            guard !rest.isEmpty else { throw CLIError("usage: saylark dict remove <term>") }
            let removed = try DictionaryFile.update(url) { $0.remove(rest) }
            guard removed else { throw CLIError("\"\(rest)\" is not in \(url.path)") }
            print("removed  \(rest)")
        case "import":
            let from = args.value("from").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? VocabularyStore.defaultURL
            // No dictionary yet: exactly what the app does on first start.
            if let moved = try DictionaryMigration.migrateIfNeeded(dictionary: url, legacy: from) {
                print("created \(url.path) from \(from.path): \(moved.terms) terms, \(moved.aliases) heard-as forms")
                if !moved.skipped.isEmpty { print("skipped (can't be written as a line): \(moved.skipped.joined(separator: ", "))") }
                return
            }
            let store = try VocabularyStore(readingOnly: from)
            let (entries, skipped) = DictionaryMigration.entries(from: try store.liveTerms())
            var added = 0, aliases = 0
            try DictionaryFile.update(url) { file in
                for e in entries {
                    let before = file.entry(e.term)
                    let after = file.add(e.term, aliases: e.aliases)
                    if before == nil { added += 1 }
                    aliases += after.aliases.count - (before?.aliases.count ?? 0)
                }
            }
            print("imported from \(from.path): \(added) new terms, \(aliases) new heard-as forms (\(entries.count) live terms read)")
            if !skipped.isEmpty { print("skipped (can't be written as a line): \(skipped.joined(separator: ", "))") }
        default:
            throw CLIError("usage: saylark dict list|add <term> [--as a,b]|remove <term>|path|import [--from FILE]  [--file FILE]")
        }
    }

    static func list(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("no dictionary yet at \(url.path). Add a term with: saylark dict add <term>")
            return
        }
        let file = try DictionaryFile.load(url)
        let entries = file.entries
        let width = min(28, entries.map(\.term.count).max() ?? 0)
        for e in entries {
            let pad = String(repeating: " ", count: max(0, width - e.term.count))
            print(e.aliases.isEmpty ? e.term : "\(e.term)\(pad)  ← \(e.aliases.joined(separator: ", "))")
        }
        print("\(entries.count) terms, \(entries.reduce(0) { $0 + $1.aliases.count }) heard-as forms  (\(url.path))")
        for p in file.problems {
            print("skipped line \(p.line): \(p.text)  (\(p.reason))")
        }
    }
}
