import Foundation

/// Tiny argument reader: the first word is the command, then positionals and `--flag value` pairs.
struct Arguments {
    let command: String?
    let positional: [String]
    private let options: [String: String]
    private let flags: Set<String>

    init<S: Sequence>(_ raw: S) where S.Element == String {
        var list = Array(raw)
        command = list.isEmpty ? nil : list.removeFirst()
        var positional: [String] = [], options: [String: String] = [:], flags: Set<String> = []
        var i = 0
        while i < list.count {
            let a = list[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < list.count, !list[i + 1].hasPrefix("--") {
                    options[key] = list[i + 1]; i += 2; continue
                }
                flags.insert(key)
            } else {
                positional.append(a)
            }
            i += 1
        }
        self.positional = positional
        self.options = options
        self.flags = flags
    }

    func flag(_ name: String) -> Bool { flags.contains(name) }
    func value(_ name: String) -> String? { options[name] }
    func double(_ name: String, _ fallback: Double) -> Double { options[name].flatMap(Double.init) ?? fallback }
    func int(_ name: String, _ fallback: Int) -> Int { options[name].flatMap(Int.init) ?? fallback }

    func requirePositional(_ i: Int, _ what: String) throws -> String {
        guard i < positional.count else { throw CLIError("missing \(what)") }
        return (positional[i] as NSString).expandingTildeInPath
    }
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func log(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try enc.encode(value).write(to: url)
}

func jsonString<T: Encodable>(_ value: T) throws -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try enc.encode(value), as: UTF8.self)
}

extension ContinuousClock.Instant {
    var msSince: Double {
        let c = duration(to: .now).components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}

/// Linear-interpolated percentile, like score.py.
func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted()
    let k = Double(s.count - 1) * p
    let f = Int(k), c = min(f + 1, s.count - 1)
    return s[f] + (s[c] - s[f]) * (k - Double(f))
}

func fmt(_ x: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", x) }
