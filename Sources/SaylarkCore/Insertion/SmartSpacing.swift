/// Spaces around inserted dictation, decided from the characters next to the caret.
///
/// - Leading space: only when the caret is known to follow a word or closing punctuation.
///   None at the start of a field, after whitespace or a newline, after an opening bracket or
///   opening quote, after `/ @ #`, after a hyphen inside a word, or when the text itself starts
///   with punctuation that attaches to the left (`,` `.` `)` …) or with a newline.
/// - Trailing space: one, like Wispr Flow, so the next dictation or typed word continues
///   naturally. None when the text ends in a newline, or when the character after the caret is
///   already whitespace or closing punctuation.
/// - Unknown context (no accessibility, Electron without text ranges): Wispr's behaviour, no
///   leading space and one trailing space. That never doubles a space after a previous dictation
///   (which ended in a space) and is right at the start of a field.
///
/// Spaces and tabs at either end of the text are dropped first, so a space is never doubled.
/// Newlines at the ends are kept (they come from "new line" commands).
public enum SmartSpacing {
    public static let openers: Set<Character> = ["(", "[", "{", "<", "“", "‘", "«", "¿", "¡", "/", "@", "#", "\\"]
    public static let leftAttaching: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", ">", "”", "’", "»", "…", "%"]
    public static let straightQuotes: Set<Character> = ["\"", "'"]

    public static func apply(_ text: String, caret: FocusInfo.Caret, trailingSpace: Bool = true) -> String {
        let body = trimSpaces(text)
        guard let first = body.first, let last = body.last else { return "" }
        var out = body
        if needsLeadingSpace(before: caret.before, first: first) { out = " " + out }
        if trailingSpace, !last.isNewline, !blocksTrailingSpace(after: caret.after) { out += " " }
        return out
    }

    static func trimSpaces(_ s: String) -> String {
        var chars = Substring(s)
        while let c = chars.first, c == " " || c == "\t" { chars = chars.dropFirst() }
        while let c = chars.last, c == " " || c == "\t" { chars = chars.dropLast() }
        return String(chars)
    }

    static func needsLeadingSpace(before: String?, first: Character) -> Bool {
        guard let before, let prev = before.last else { return false }  // unknown or field start
        if first.isWhitespace || leftAttaching.contains(first) { return false }
        if prev.isWhitespace { return false }
        if openers.contains(prev) { return false }
        let prevPrev = before.dropLast().last
        if straightQuotes.contains(prev) || prev == "-" {
            // Quote or hyphen right after whitespace / the field start: an opening quote (no
            // space: `"word`) or a dash (space: `next - word`). Right after a word: a closing
            // quote or apostrophe (space: `"hi" word`) or a hyphen (no space: `re-word`).
            let afterBoundary = prevPrev == nil || prevPrev!.isWhitespace || openers.contains(prevPrev!)
            if prev == "-" { return afterBoundary }
            return !afterBoundary
        }
        return true
    }

    static func blocksTrailingSpace(after: String?) -> Bool {
        guard let after, let next = after.first else { return false }  // unknown or end of field
        return next.isWhitespace || leftAttaching.contains(next) || straightQuotes.contains(next)
    }
}
