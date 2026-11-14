import Foundation

/// The recogniser glues a name to the number after it ("Opus5.5", "Lyria3.5"). These helpers find
/// such tokens and count, in the user's own writing, whether a term is written apart from numbers,
/// so only those terms are split. Identifiers ("base64", "sha256", "MP4", "GPT4") are untouched
/// unless their prefix is a term the user writes apart.
public enum NumberSpacing {
    /// Never split, whatever the vocabulary says.
    public static let identifiers: Set<String> = [
        "base64", "base32", "sha1", "sha256", "sha512", "md5", "utf8", "utf16", "utf32", "mp3", "mp4", "m4a", "h264", "h265",
        "x86", "x64", "arm64", "win32", "win64", "ipv4", "ipv6", "i18n", "l10n", "k8s", "a11y", "web3", "p2p", "b2b", "b2c",
    ]

    /// "Opus5.5" → ("Opus", "5.5"); nil unless the token is letters followed by a number
    /// (digits with optional dots).
    public static func split(_ core: String) -> (prefix: String, number: String)? {
        guard let d = core.firstIndex(where: \.isNumber), d > core.startIndex else { return nil }
        let prefix = core[..<d], number = core[d...]
        guard prefix.allSatisfy(\.isLetter), number.allSatisfy({ $0.isNumber || $0 == "." }),
              number.last?.isNumber == true, !number.contains("..") else { return nil }
        return (String(prefix), String(number))
    }

    /// How often each of `keys` is followed by a number with a space ("Opus 4.5") and glued to
    /// one ("Opus4.5") in this text.
    public static func count(in text: String, keys: Set<String>) -> (apart: [String: Int], joined: [String: Int]) {
        var apart: [String: Int] = [:], joined: [String: Int] = [:]
        let words = text.split(whereSeparator: \.isWhitespace).map { TermSwapper.split(String($0)) }
        for (i, w) in words.enumerated() {
            if let s = split(w.core) {
                let k = SoundKey.spelling(s.prefix)
                if keys.contains(k), !identifiers.contains(w.core.lowercased()) { joined[k, default: 0] += 1 }
            } else if w.trail.isEmpty, i + 1 < words.count, words[i + 1].lead.isEmpty,
                      words[i + 1].core.first?.isNumber == true, w.core.allSatisfy(\.isLetter) {
                let k = SoundKey.spelling(w.core)
                if keys.contains(k) { apart[k, default: 0] += 1 }
            }
        }
        return (apart, joined)
    }
}
