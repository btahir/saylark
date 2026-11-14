import Foundation

/// The result of one transcription: text plus per-word and per-token timing and confidence.
/// Times are in seconds from the start of the dictation.
public struct Transcript: Codable, Sendable, Equatable {
    public var text: String
    public var words: [TranscriptWord]
    public var tokens: [TranscriptToken]

    public init(text: String, words: [TranscriptWord] = [], tokens: [TranscriptToken] = []) {
        self.text = text
        self.words = words
        self.tokens = tokens
    }

    public static let empty = Transcript(text: "")

    /// Joins windows in order. Windows are cut in silence, so there is no overlap to remove.
    public static func joined(_ parts: [Transcript]) -> Transcript {
        let nonEmpty = parts.filter { !$0.text.isEmpty }
        return Transcript(
            text: nonEmpty.map(\.text).joined(separator: " "),
            words: nonEmpty.flatMap(\.words),
            tokens: nonEmpty.flatMap(\.tokens)
        )
    }

    /// Shifts every timing by `seconds` (used to place a window inside the whole dictation).
    public func shifted(by seconds: Double) -> Transcript {
        Transcript(
            text: text,
            words: words.map { TranscriptWord(text: $0.text, start: $0.start + seconds, end: $0.end + seconds, confidence: $0.confidence) },
            tokens: tokens.map { TranscriptToken(text: $0.text, start: $0.start + seconds, end: $0.end + seconds, confidence: $0.confidence, tokenId: $0.tokenId) }
        )
    }
}

/// One word, built from its sub-word tokens. Confidence is the lowest token confidence in the word.
public struct TranscriptWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float

    public init(text: String, start: Double, end: Double, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// One sub-word token as the model emitted it. A leading space marks the start of a word.
public struct TranscriptToken: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var confidence: Float
    /// The model's vocabulary id for this token. Needed to hand tokens back to FluidAudio (the
    /// vocabulary rescorer takes `TokenTiming`s). Nil in records saved before it was kept.
    public var tokenId: Int?

    public init(text: String, start: Double, end: Double, confidence: Float, tokenId: Int? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
        self.tokenId = tokenId
    }

    /// Groups tokens into words. A token starting with a space (or SentencePiece `▁`) begins a
    /// new word; other tokens, including punctuation, attach to the current word.
    public static func words(from tokens: [TranscriptToken]) -> [TranscriptWord] {
        var words: [TranscriptWord] = []
        for token in tokens {
            let raw = token.text.replacingOccurrences(of: "▁", with: " ")
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if raw.hasPrefix(" ") || words.isEmpty {
                words.append(TranscriptWord(text: trimmed, start: token.start, end: token.end, confidence: token.confidence))
            } else {
                words[words.count - 1].text += trimmed
                words[words.count - 1].end = token.end
                words[words.count - 1].confidence = min(words[words.count - 1].confidence, token.confidence)
            }
        }
        return words
    }
}
