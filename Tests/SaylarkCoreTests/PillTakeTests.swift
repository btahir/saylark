import Foundation
import Testing
@testable import SaylarkCore

/// Pill events carry their take's id; a late event from an earlier take never touches the current
/// take's pill.
@Suite struct PillTakeTests {
    let a = UUID(), b = UUID()

    /// Before: take A's slow finish arrived while take B was recording and collapsed B's pill.
    @Test func lateFinishFromAnEarlierTakeIsIgnored() {
        var m = PillMachine()
        m.handle(.listen, take: a, at: 0)
        m.handle(.listen, take: b, at: 1)  // A's release was handled; its text is still coming
        m.handle(.finish(.inserted), take: a, at: 1.2)
        #expect(m.state.phase == .listening)
        #expect(m.state.take == b)
        m.handle(.fail(.transcriptionFailed), take: a, at: 1.3)
        m.handle(.words(["old"]), take: a, at: 1.4)
        #expect(m.state.phase == .listening)
        #expect(m.state.words.isEmpty)
        m.handle(.finish(.inserted), take: b, at: 2)
        #expect(m.state.phase == .done)
    }

    @Test func eventsWithoutATakeStillApply() {
        var m = PillMachine()
        m.handle(.listen, take: a, at: 0)
        m.handle(.hover(true), at: 0.5)
        #expect(m.state.hovering)
        m.handle(.finish(.noTextField("hi")), take: a, at: 1)
        m.handle(.dismiss, at: 2)
        #expect(m.state.phase == .hidden)
        // A mic failure between takes (no take) still shows.
        m.handle(.fail(.microphoneMissing(name: "Q2U")), at: 3)
        #expect(m.state.phase == .error(.microphoneMissing(name: "Q2U")))
    }

    @Test func liveSessionPassesTakeIDs() {
        var s = LivePillSession()
        s.handle(.pill(.listen, take: a), at: 0)
        s.handle(.pill(.listen, take: b), at: 1)
        s.handle(.pill(.finish(.empty), take: a), at: 1.5)
        #expect(s.state.phase == .listening)
        s.handle(.pill(.finish(.empty), take: b), at: 2)
        #expect(s.state.phase == .done)
    }

    @Test func recordsDecodeWithoutTheNewRecoveredField() throws {
        let r = DictationRecord(startedAt: Date(timeIntervalSince1970: 1000), duration: 1, mode: .shadow, handsFree: false, rawText: "a", cleanText: "a", outcome: .failed)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        json["recovered"] = nil
        let back = try JSONDecoder().decode(DictationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back == r)
        #expect(!back.recovered)
    }
}
