import Foundation
import SaylarkCore

/// The quiet numbers at the top of Home.
public struct LibraryStats: Sendable, Equatable {
    public var wordsToday = 0
    public var wordsThisWeek = 0
    public var minutesToday = 0.0
    /// Takes with words in them today.
    public var takesToday = 0
    /// Median Fn-release → text, in ms, over the last week.
    public var medianTimeToTextMs: Double?

    public init() {}

    public static func compute(_ records: [DictationRecord], now: Date = Date(), calendar: Calendar = .current) -> LibraryStats {
        var s = LibraryStats()
        let today = calendar.startOfDay(for: now)
        let weekAgo = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        var latencies: [Double] = []
        for r in records where r.outcome != .cancelled && r.outcome != .empty {
            let words = r.cleanText.split(whereSeparator: \.isWhitespace).count
            if r.startedAt >= today {
                s.wordsToday += words
                s.minutesToday += r.duration / 60
                if words > 0 { s.takesToday += 1 }
            }
            guard r.startedAt >= weekAgo else { continue }
            s.wordsThisWeek += words
            if let ms = r.releaseToTextMs { latencies.append(ms) }
        }
        s.medianTimeToTextMs = median(latencies)
        return s
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let v = values.sorted(), n = v.count
        return n % 2 == 1 ? v[n / 2] : (v[n / 2 - 1] + v[n / 2]) / 2
    }
}
