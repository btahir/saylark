import Foundation
import SaylarkCore

/// A dictionary for renders and the fake-engine app, written to a temp file so the user's real
/// `dictionary.txt` is never read or changed.
public enum SampleDictionary {
    public static let text = DictionaryFile.header + "\n" + """
        Anthropic: entropic
        Claude Code: cloud code, clawed code
        Codex: codecs
        ElevenLabs: eleven labs, level labs
        Figma: fig ma, Vigma
        GitHub: get hub, git hub
        kubectl
        Next.js: next just
        Postgres: post gress
        Supabase: super base
        Tailwind: tail wind, Telwind
        TensorFlow: tensor flow, tense or flow
        Vercel: Versel, worsel

        """

    /// Lines the parser skips, for the "skipped lines" notice.
    public static let withProblems = text + """
        : heard as nothing
        Foo, Bar

        """

    /// Writes `contents` to a fresh temp folder and returns the file.
    public static func write(_ contents: String = text) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("saylark-sample-\(UUID().uuidString)")
        let url = folder.appendingPathComponent("dictionary.txt")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(contents.utf8).write(to: url)
        return url
    }
}
