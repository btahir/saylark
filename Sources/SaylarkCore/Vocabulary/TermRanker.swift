import Foundation

/// Something known about the moment of a take that makes some terms more likely. Later sources
/// (window title, on-screen text, the agent's last reply) implement this too; the ranker adds up
/// every signal's boost.
public protocol TermContextSignal: Sendable {
    var name: String { get }
    func boost(for term: VocabularyTerm) -> Double
}

/// The project the user is working in (for Claude Code / Codex: the session's working folder).
/// Terms said in that project before, and the project's own name, rank higher.
public struct ProjectSignal: TermContextSignal {
    public let project: String
    public var name: String { "project:\(project)" }

    /// `folder` may be a path; the last component is used.
    public init(folder: String) {
        project = (folder as NSString).lastPathComponent.lowercased()
    }

    public func boost(for term: VocabularyTerm) -> Double {
        if term.key == SoundKey.spelling(project) { return 10 }
        return term.projects.contains(project) ? 6 : 0
    }
}

/// What Saylark knows about the take being corrected.
public struct VocabularyContext: Sendable {
    /// Frontmost app when the take started.
    public var appBundleID: String?
    /// For agent apps, the project folder of the active session.
    public var projectFolder: String?
    /// Extra signals; `projectFolder` adds a `ProjectSignal` on its own.
    public var extraSignals: [any TermContextSignal]

    public init(appBundleID: String? = nil, projectFolder: String? = nil, extraSignals: [any TermContextSignal] = []) {
        self.appBundleID = appBundleID
        self.projectFolder = projectFolder
        self.extraSignals = extraSignals
    }

    public static let none = VocabularyContext()

    public var signals: [any TermContextSignal] {
        (projectFolder.map { [ProjectSignal(folder: $0)] } ?? []) + extraSignals
    }

    /// Bundle IDs of the agent apps whose session folder is looked up.
    public static let agentApps: Set<String> = ["com.anthropic.claudefordesktop", "com.openai.codex"]
}

/// Picks the terms to use for one take: the global score plus every context signal's boost.
public enum TermRanker {
    public static func select(_ terms: [VocabularyTerm], context: VocabularyContext, limit: Int, now: Date) -> [VocabularyTerm] {
        let signals = context.signals
        let scored = terms.filter { $0.state == .live }.map { t in
            (t, VocabularyBook.score(t, now: now) + signals.reduce(0) { $0 + $1.boost(for: t) })
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.key < $1.0.key }.prefix(limit).map(\.0)
    }
}
