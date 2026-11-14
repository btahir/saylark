import Foundation
import SaylarkCore

/// Invented takes for the fake engine, tests and review renders. None of this is the user's text.
public enum SampleTakes {
    struct Sample {
        let minutesAgo: Double
        let seconds: Double
        let app: (id: String, name: String)
        let text: String
        let ms: Double
        var handsFree = false
    }

    static let claude = (id: "com.anthropic.claudefordesktop", name: "Claude")
    static let codex = (id: "com.openai.codex", name: "Codex")
    static let chrome = (id: "com.google.Chrome", name: "Chrome")
    static let slack = (id: "com.tinyspeck.slackmacgap", name: "Slack")
    static let notes = (id: "com.apple.Notes", name: "Notes")
    static let ghostty = (id: "com.mitchellh.ghostty", name: "Ghostty")

    static let samples: [Sample] = [
        Sample(minutesAgo: 4, seconds: 6.2, app: claude,
               text: "Can you check why the preview deploy failed on Vercel and fix the environment variable name?",
               ms: 48),
        Sample(minutesAgo: 11, seconds: 23.5, app: codex,
               text: "Okay, so the plan for the library window is one list grouped by day. Each row shows the first two lines, the app icon, the time and how long the take was. Hover shows copy and play. Keep the header quiet.",
               ms: 61, handsFree: true),
        Sample(minutesAgo: 26, seconds: 3.1, app: slack,
               text: "Running five minutes late, start without me.",
               ms: 41),
        Sample(minutesAgo: 48, seconds: 9.8, app: claude,
               text: "Use the new logo in the header and keep the footer links on one line. The build should go through the release script.",
               ms: 52),
        Sample(minutesAgo: 95, seconds: 14.6, app: ghostty,
               text: "Let's rebase onto main, rerun the tests with the UI scratch path, and then commit only the files we own.",
               ms: 57),
        Sample(minutesAgo: 140, seconds: 4.4, app: notes,
               text: "Ideas: a quieter stop sound, and the card should wait while I hover.",
               ms: 44),
        Sample(minutesAgo: 60 * 20, seconds: 31.0, app: codex,
               text: "Refactor the settings page so it's one column with about eight items. Shortcut first, then microphone, mode, voice visual, live words, accent, how long to keep audio, launch at login and sounds. Anything else goes under Advanced.",
               ms: 73, handsFree: true),
        Sample(minutesAgo: 60 * 21, seconds: 5.0, app: chrome,
               text: "Pricing page, annual plan comparison",
               ms: 46),
        Sample(minutesAgo: 60 * 22.5, seconds: 7.7, app: claude,
               text: "What's the difference between a listen-only event tap and an IOHID monitor for the Fn key?",
               ms: 50),
        Sample(minutesAgo: 60 * 23.2, seconds: 2.4, app: slack,
               text: "Sounds good, ship it.",
               ms: 39),
        Sample(minutesAgo: 60 * 46, seconds: 12.1, app: claude,
               text: "Pull the old demo link from the README and replace it with the recording we made on Tuesday.",
               ms: 55),
        Sample(minutesAgo: 60 * 47, seconds: 18.3, app: codex,
               text: "Run the test suite on both machines, then post the timings next to last week's numbers. If anything is over a hundred and fifty milliseconds, show me which tests.",
               ms: 64, handsFree: true),
        Sample(minutesAgo: 60 * 70, seconds: 3.6, app: notes,
               text: "Buy coffee filters and oat milk.",
               ms: 42),
    ]

    /// The samples as records, newest first, with times relative to `now`.
    public static func records(now: Date = Date()) -> [DictationRecord] {
        samples.enumerated().map { i, s in
            let words = timedWords(s.text, seconds: s.seconds)
            return DictationRecord(
                id: UUID(uuidString: String(format: "5A71A2C0-0000-4000-8000-%012d", i))!,
                startedAt: now.addingTimeInterval(-s.minutesAgo * 60), duration: s.seconds, mode: .active,
                handsFree: s.handsFree, appBundleID: s.app.id, appName: s.app.name, rawText: s.text, cleanText: s.text,
                words: words, releaseToTextMs: s.ms, outcome: .inserted, audioPath: "sample-\(i).m4a")
        }
    }

    /// The samples as a varied history: every way a take can end. Newest first.
    public static func history(now: Date = Date()) -> [DictationRecord] {
        var out = records(now: now)
        out[0].sent = true
        out[1].sent = true
        out[3].outcome = .card
        out[4].outcome = .cancelled
        out[5].outcome = .failed
        out[5].rawText = ""; out[5].cleanText = ""; out[5].words = []
        out[6].recovered = true
        out[7].outcome = .copied
        out[9].outcome = .cancelled
        out[9].rawText = ""; out[9].cleanText = ""; out[9].words = []
        return out
    }

    /// Spreads words over the take like speech: longer words take longer, with small pauses after
    /// commas and full stops.
    static func timedWords(_ text: String, seconds: Double) -> [TranscriptWord] {
        let tokens = text.split(separator: " ").map(String.init)
        let weights = tokens.map { t -> Double in
            Double(t.count) * 0.06 + 0.12 + (t.hasSuffix(",") ? 0.18 : 0) + (t.hasSuffix(".") || t.hasSuffix("?") ? 0.32 : 0)
        }
        let lead = 0.25, tail = 0.3
        let scale = max(0.1, seconds - lead - tail) / weights.reduce(0, +)
        var t = lead
        return zip(tokens, weights).map { word, w in
            let span = w * scale
            let pause = (word.hasSuffix(",") ? 0.18 : word.hasSuffix(".") || word.hasSuffix("?") ? 0.32 : 0) * scale
            let out = TranscriptWord(text: word, start: t, end: t + span - pause, confidence: 0.95)
            t += span
            return out
        }
    }

    /// A speech-like level envelope (0...1, 120 Hz) built from word timings: a bump per syllable-ish
    /// chunk of each word, quiet in pauses. Used where the fake has no audio file.
    public static func envelope(for record: DictationRecord, rate: Double = 120) -> [Float] {
        let n = max(1, Int(record.duration * rate))
        var out = [Float](repeating: 0.02, count: n)
        for (wi, w) in record.words.enumerated() {
            let syllables = max(1, w.text.count / 3)
            let len = (w.end - w.start) / Double(syllables)
            for s in 0..<syllables {
                let a = w.start + Double(s) * len, b = a + len
                let peak = 0.55 + 0.4 * Float(abs(sin(Double(wi * 7 + s * 3))))
                for i in Int(a * rate)..<min(n, Int(b * rate)) {
                    let x = (Double(i) / rate - a) / len
                    out[i] = max(out[i], peak * Float(sin(.pi * x)))
                }
            }
        }
        return out
    }
}
