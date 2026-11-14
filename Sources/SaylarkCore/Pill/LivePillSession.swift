import Foundation

/// Feeds the engine's `DictationEvent`s into a `PillMachine` on a live clock. The engine sends levels
/// at about 120 per second; the pill reads the newest one each display frame. Pure and deterministic,
/// so the same code runs live, in tests and in the fake engine's replays.
public struct LivePillSession: Sendable {
    public private(set) var machine: PillMachine
    /// Newest level of the current take and the clock time it arrived.
    private var latest: VoiceLevel?
    private var latestAt = -Double.infinity
    /// A level older than this counts as silence, so a stalled engine shows as "no signal".
    public var staleAfter = 0.25

    public init(config: PillConfig = PillConfig()) {
        machine = PillMachine(config: config)
    }

    public var state: PillState { machine.state }

    /// Applies one engine event at `time` (the session's clock, seconds). Returns the record when the
    /// event was `.saved`, so the caller can pass it on to the Library and the menu.
    @discardableResult
    public mutating func handle(_ event: DictationEvent, at time: Double) -> DictationRecord? {
        switch event {
        case .pill(let e, let take):
            if e == .listen { latest = nil; latestAt = -.infinity }
            machine.handle(e, take: take, at: time)
            machine.tick(at: time, peakDB: peakDB(at: time))
            return nil
        case .level(let level):
            latest = level
            latestAt = time
            return nil
        case .saved(let record):
            return record
        }
    }

    /// Ticks the machine and returns what the pill draws this frame. `rms` is linear (nil when the
    /// pill is not listening).
    public mutating func frame(at time: Double) -> (state: PillState, rms: Float?) {
        machine.tick(at: time, peakDB: peakDB(at: time))
        guard machine.state.phase == .listening else { return (machine.state, nil) }
        guard let latest, time - latestAt <= staleAfter else { return (machine.state, 0) }
        return (machine.state, Float(pow(10, Double(latest.rmsDB) / 20)))
    }

    private func peakDB(at time: Double) -> Double? {
        guard machine.state.phase == .listening else { return nil }
        guard let latest, time - latestAt <= staleAfter else { return -120 }
        return Double(latest.peakDB)
    }
}
