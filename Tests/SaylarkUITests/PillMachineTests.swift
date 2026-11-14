import Testing
import SaylarkCore

/// The pill's state model, driven by events and time like the real app and the lab.
@Suite struct PillMachineTests {
    private func machine() -> PillMachine { PillMachine() }

    @Test func holdTakeLandsThenHides() {
        var m = machine()
        m.handle(.listen, at: 1)
        #expect(m.state.phase == .listening)
        #expect(m.state.mode == .hold)
        m.handle(.finish(.inserted), at: 3)
        #expect(m.state.phase == .done)
        m.tick(at: 3.1, peakDB: nil)
        #expect(m.state.phase == .done)
        m.tick(at: 3.3, peakDB: nil)
        #expect(m.state.phase == .hidden)
    }

    @Test func handsFreeKeepsTimerFromTakeStart() {
        var m = machine()
        m.handle(.listen, at: 10)
        m.handle(.lockHandsFree, at: 10.3)
        #expect(m.state.mode == .handsFree)
        #expect(m.state.elapsed(at: 22.5) == 12.5)
    }

    @Test func noSignalAfterTwoSecondsOfDeadInputAndRecovers() {
        var m = machine()
        m.handle(.listen, at: 0)
        var t = 0.0
        while t < 1.99 { m.tick(at: t, peakDB: -120); t += 1.0 / 120 }
        #expect(!m.state.noSignal)
        m.tick(at: 2.01, peakDB: -120)
        #expect(m.state.noSignal)
        m.tick(at: 2.5, peakDB: -30)
        #expect(!m.state.noSignal)
    }

    @Test func roomToneIsNotNoSignal() {
        var m = machine()
        m.handle(.listen, at: 0)
        for i in 0..<600 { m.tick(at: Double(i) / 120, peakDB: -66) }
        #expect(!m.state.noSignal)
    }

    @Test func cardWaitsForHoverAndTimesOut() {
        var m = machine()
        m.handle(.listen, at: 0)
        m.handle(.finish(.noTextField("hello")), at: 1)
        #expect(m.state.phase == .card(text: "hello"))
        m.handle(.hover(true), at: 5)
        m.tick(at: 20, peakDB: nil)
        #expect(m.state.phase == .card(text: "hello"), "hover keeps it open")
        m.handle(.hover(false), at: 20)
        m.tick(at: 27.9, peakDB: nil)
        #expect(m.state.phase == .card(text: "hello"), "timeout restarts after hover")
        m.tick(at: 28.1, peakDB: nil)
        #expect(m.state.phase == .hidden)
    }

    @Test func pasteWhenFocusedThenFieldFocused() {
        var m = machine()
        m.handle(.listen, at: 0)
        m.handle(.finish(.noTextField("hi")), at: 1)
        m.handle(.pasteWhenFocused, at: 2)
        #expect(m.state.phase == .waitingForField(text: "hi"))
        m.tick(at: 60, peakDB: nil)
        #expect(m.state.phase == .waitingForField(text: "hi"), "waits until a field or dismiss")
        m.handle(.fieldFocused, at: 61)
        #expect(m.state.phase == .done)
    }

    @Test func escCancelsThenHides() {
        var m = machine()
        m.handle(.listen, at: 0)
        m.handle(.cancel, at: 1)
        #expect(m.state.phase == .cancelled)
        m.tick(at: 1.6, peakDB: nil)
        #expect(m.state.phase == .hidden)
    }

    @Test func newTakeInterruptsDismissal() {
        var m = machine()
        m.handle(.listen, at: 0)
        m.handle(.words(["one", "two"]), at: 0.5)
        m.handle(.finish(.inserted), at: 1)
        m.handle(.listen, at: 1.05)
        #expect(m.state.phase == .listening)
        #expect(m.state.words.isEmpty)
        #expect(m.state.takeStart == 1.05)
    }

    @Test func eventsOutOfPlaceAreIgnored() {
        var m = machine()
        m.handle(.finish(.inserted), at: 0)
        m.handle(.cancel, at: 0)
        m.handle(.lockHandsFree, at: 0)
        m.handle(.fieldFocused, at: 0)
        #expect(m.state.phase == .hidden)
        m.handle(.listen, at: 1)
        m.handle(.pasteWhenFocused, at: 1.1)
        #expect(m.state.phase == .listening)
    }

    @Test func liveWordsKeepNewestAndCount() {
        var m = machine()
        m.handle(.listen, at: 0)
        let words = (1...20).map { "w\($0)" }
        m.handle(.words(words), at: 1)
        #expect(m.state.words.count == m.config.maxWords)
        #expect(m.state.words.last == "w20")
        #expect(m.state.wordCount == 20)
    }

    @Test func errorTimesOutOrDismisses() {
        var m = machine()
        m.handle(.fail(.microphoneAccessOff), at: 0)
        #expect(m.state.phase == .error(.microphoneAccessOff))
        m.tick(at: 6.1, peakDB: nil)
        #expect(m.state.phase == .hidden)
        m.handle(.fail(.accessibilityOff), at: 7)
        m.handle(.dismiss, at: 7.5)
        #expect(m.state.phase == .hidden)
    }
}

@Suite struct PillDriverTests {
    @Test func appliesEventsInTimeOrderAndKeepsTies() {
        var d = PillDriver(events: [TimedPillEvent(2, .finish(.inserted)), TimedPillEvent(1, .listen),
                                    TimedPillEvent(1, .lockHandsFree)])
        d.advance(to: 0.5)
        #expect(d.state.phase == .hidden)
        let applied = d.advance(to: 1.0)
        #expect(applied == [.listen, .lockHandsFree])
        #expect(d.state.mode == .handsFree)
        d.advance(to: 2.0)
        #expect(d.state.phase == .done)
        #expect(d.rms(at: 2.0) == nil)
    }

    @Test func voiceDrivesNoSignal() {
        let dead = VoiceEnvelope.constant(id: "dead", seconds: 5, db: -130)
        var d = PillDriver(events: [TimedPillEvent(0, .listen)], voice: dead)
        var t = 0.0
        while t < 2.2 { d.advance(to: t); t += 1.0 / 120 }
        #expect(d.state.noSignal)
    }
}
