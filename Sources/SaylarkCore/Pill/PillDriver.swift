/// One event at a time on a scripted timeline.
public struct TimedPillEvent: Sendable, Equatable {
    public var time: Double
    public var event: PillEvent

    public init(_ time: Double, _ event: PillEvent) {
        self.time = time
        self.event = event
    }
}

/// Plays a scripted timeline into a `PillMachine`, frame by frame. Used by the offscreen renderer,
/// the lab and the tests, so a scenario looks the same everywhere.
public struct PillDriver: Sendable {
    public private(set) var machine: PillMachine
    public let events: [TimedPillEvent]
    /// The voice: drives no-signal detection. Time 0 of the envelope is the moment of `voiceStart`.
    public let voice: VoiceEnvelope?
    public let voiceStart: Double
    private var next = 0
    public private(set) var time: Double = 0

    public init(events: [TimedPillEvent], voice: VoiceEnvelope? = nil, voiceStart: Double = 0, config: PillConfig = PillConfig()) {
        // Stable sort: events at the same time keep their written order.
        self.events = events.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        self.voice = voice
        self.voiceStart = voiceStart
        self.machine = PillMachine(config: config)
    }

    public var state: PillState { machine.state }

    /// RMS of the voice at `time`, or nil when the pill is not listening.
    public func rms(at time: Double) -> Float? {
        guard machine.state.phase == .listening else { return nil }
        return voice?.rms(at: time - voiceStart) ?? 0
    }

    /// Applies every event up to and including `time`, then ticks. Returns the events applied.
    @discardableResult
    public mutating func advance(to time: Double) -> [PillEvent] {
        var applied: [PillEvent] = []
        while next < events.count, events[next].time <= time {
            let e = events[next]
            machine.handle(e.event, at: e.time)
            // Tick at the event time too, so timeouts that expire between frames land in order.
            machine.tick(at: e.time, peakDB: peakDB(at: e.time))
            applied.append(e.event)
            next += 1
        }
        machine.tick(at: time, peakDB: peakDB(at: time))
        self.time = time
        return applied
    }

    private func peakDB(at time: Double) -> Double? {
        guard machine.state.phase == .listening else { return nil }
        guard let voice else { return -120 }
        return voice.peak(at: time - voiceStart).dBFS
    }

    /// Time of the last event, so callers know how long to keep rendering.
    public var lastEventTime: Double { events.last?.time ?? 0 }
}
