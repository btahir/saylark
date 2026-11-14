import AppKit
import Foundation
import QuartzCore
import Testing
import SaylarkCore
@testable import SaylarkUI

/// Card clicks that must work the first time: where the buttons take clicks, which window takes
/// them, and the pressed look. Nothing here is put on screen.
@MainActor @Suite struct PillClickTests {
    static let text = "Can you check why the preview deploy failed and fix the environment variable name?"

    /// Drives `view` frame by frame (120 Hz) through `events` up to `seconds`, calling `each` after
    /// every frame with its time.
    private func drive(_ view: PillView, _ events: [TimedPillEvent], seconds: Double, each: (Double) -> Void = { _ in }) {
        var d = PillDriver(events: events)
        for i in 0...Int(seconds * 120) {
            let t = Double(i) / 120
            CATransactionScope.run {
                d.advance(to: t)
                view.update(state: d.state, time: t, rms: d.state.phase == .listening ? 0.02 : nil, dt: 1 / 120)
            }
            each(t)
        }
    }

    private func card(_ outcome: PillOutcome) -> [TimedPillEvent] {
        [TimedPillEvent(0, .listen), TimedPillEvent(0.5, .finish(outcome))]
    }

    private func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // Root cause 1: hit areas came from the animated layout and needed the button more than half
    // faded in, so a click in the first ~200 ms of the card went to the app behind.
    @Test func cardButtonsTakeClicksFromTheFirstFrame() {
        let v = PillView()
        drive(v, card(.noTextField(Self.text)), seconds: 0.5 + 1.0 / 120)
        for hit in [PillHit.copy, .pasteWhenFocused, .dismiss] {
            let r = v.hitRect(hit)
            #expect(r != nil, "\(hit) has no hit area one frame after the card was decided")
            if let r { #expect(v.hit(center(r)) == hit) }
        }
    }

    @Test func hitAreasStayPutWhileTheCardOpens() {
        let v = PillView()
        var seen: [CGRect?] = []
        drive(v, card(.noTextField(Self.text)), seconds: 1.5) { t in
            if t > 0.5 { seen.append(v.hitRect(.pasteWhenFocused)) }
        }
        let settled = v.hitRect(.pasteWhenFocused)
        #expect(settled != nil)
        #expect(seen.allSatisfy { $0 == settled }, "the paste button's hit area moved while the card animated")
    }

    @Test func noticeAndStopButtonsAlsoTakeClicksAtOnce() {
        let v = PillView()
        drive(v, card(.noTextField(Self.text)) + [TimedPillEvent(2, .pasteWhenFocused)], seconds: 2 + 1.0 / 120)
        let cancel = v.hitRect(.dismiss)
        #expect(cancel != nil)
        if let cancel { #expect(v.hit(center(cancel)) == .dismiss) }

        let h = PillView()
        drive(h, [TimedPillEvent(0, .listen), TimedPillEvent(0.3, .lockHandsFree)], seconds: 0.3 + 1.0 / 120)
        #expect(h.hitRect(.stop) != nil)
    }

    // Root cause 2: the panel switched `ignoresMouseEvents` from the pointer position once per
    // frame, always after the pointer had arrived, so the first click could go to the app behind.
    // Now the click area is decided from the state alone, with no pointer input at all.
    @Test func clickZoneFollowsTheStateNotThePointer() {
        let v = PillView()
        drive(v, [TimedPillEvent(0, .listen)], seconds: 0.5)
        #expect(v.clickZone == nil, "hold-to-talk has nothing to click; clicks go to the app behind")

        drive(v, card(.noTextField(Self.text)), seconds: 0.5 + 1.0 / 120)
        let zone = v.clickZone
        #expect(zone != nil)
        if let zone {
            for hit in [PillHit.copy, .pasteWhenFocused, .dismiss] {
                #expect(v.hitRect(hit).map { zone.contains($0) } == true)
            }
        }

        drive(v, card(.noTextField(Self.text)) + [TimedPillEvent(1, .dismiss)], seconds: 1.1)
        #expect(v.clickZone == nil)
    }

    @Test func panelTakesTheFirstClickWithoutTouchingIgnoresMouseEvents() {
        let p = PillPanel()
        p.ordersWindows = false
        var hits: [PillHit] = []
        p.onHit = { hits.append($0) }
        drive(p.view, card(.noTextField(Self.text)), seconds: 0.5 + 1.0 / 120)
        p.syncClickPanel()

        #expect(p.panel.ignoresMouseEvents, "the drawing panel never takes clicks")
        #expect(!p.clickPanel.ignoresMouseEvents)
        #expect(!p.clickPanel.canBecomeKey && p.clickPanel.styleMask.contains(.nonactivatingPanel))
        let zone = p.view.clickZone!.integral
        let origin = p.panel.frame.origin
        #expect(p.clickFrame == zone.offsetBy(dx: origin.x, dy: origin.y))

        // A press on Copy, in the click panel's own coordinates, as AppKit delivers it.
        let copy = p.view.hitRect(.copy)!
        p.mouseDown(at: CGPoint(x: copy.midX - zone.minX, y: copy.midY - zone.minY))
        #expect(hits == [.copy])
        #expect(p.view.pressAmount(.copy) == 1, "pressed look on mouse down")

        // A press between buttons is the pill's, and does nothing.
        p.mouseDown(at: CGPoint(x: 6, y: zone.height - 6))
        #expect(hits == [.copy])

        // The pill goes away: so does the click panel.
        drive(p.view, card(.noTextField(Self.text)) + [TimedPillEvent(1, .dismiss)], seconds: 2)
        p.syncClickPanel()
        #expect(p.clickFrame == nil)
    }

    @Test func pressedLookShowsAtOnceAndFadesAfterRelease() {
        let v = PillView()
        drive(v, card(.noTextField(Self.text)), seconds: 1.5)
        #expect(v.pressAmount(.pasteWhenFocused) == 0)
        v.setPressed(.pasteWhenFocused)
        #expect(v.pressAmount(.pasteWhenFocused) == 1)
        #expect(v.pressAmount(.copy) == 0)
        v.setPressed(nil)
        drive(v, card(.noTextField(Self.text)), seconds: 0.5)
        #expect(v.pressAmount(.pasteWhenFocused) < 0.01)
    }

    // Auto-copy: the card says it is copied and has no Copy button.
    @Test func copiedCardOffersPasteLaterAndDismissOnly() {
        let v = PillView()
        drive(v, card(.noTextFieldCopied(Self.text)), seconds: 1.5)
        #expect(v.hitRect(.copy) == nil)
        #expect(v.hitRect(.pasteWhenFocused) != nil)
        #expect(v.hitRect(.dismiss) != nil)
        #expect(PillView.copiedNote == "Copied. Press \u{2318}V to paste.")

        let plain = PillView()
        drive(plain, card(.noTextField(Self.text)), seconds: 1.5)
        // Auto-copy off: the same card size, with "No text field was focused." and a Copy button.
        #expect(v.pillFrame.height == plain.pillFrame.height)
        #expect(plain.hitRect(.copy) != nil)
        #expect(PillView.noFieldNote == "No text field was focused.")
    }
}

@Suite struct CopiedCardMachineTests {
    @Test func copiedCardKeepsItsFlagThroughPasteLaterAndClearsOnTheNextTake() {
        var m = PillMachine()
        m.handle(.listen, at: 0)
        m.handle(.finish(.noTextFieldCopied("hello")), at: 1)
        #expect(m.state.phase == .card(text: "hello"))
        #expect(m.state.cardCopied && m.state.cardReason == nil)
        m.handle(.pasteWhenFocused, at: 2)
        #expect(m.state.phase == .waitingForField(text: "hello"))
        m.handle(.listen, at: 3)
        #expect(!m.state.cardCopied)
        m.handle(.finish(.noTextField("x")), at: 4)
        #expect(!m.state.cardCopied)
    }

    @Test func cardStaysWhileHoveredAndTimesOutFromTheEndOfTheHover() {
        var m = PillMachine()
        m.handle(.listen, at: 0)
        m.handle(.finish(.noTextFieldCopied("hello")), at: 1)
        m.handle(.hover(true), at: 8.5)
        m.tick(at: 30, peakDB: nil)
        #expect(m.state.phase == .card(text: "hello"), "never closes under the pointer")
        m.handle(.hover(false), at: 30)
        m.tick(at: 30 + m.config.cardTimeout - 0.1, peakDB: nil)
        #expect(m.state.phase == .card(text: "hello"))
        m.tick(at: 30 + m.config.cardTimeout + 0.01, peakDB: nil)
        #expect(m.state.phase == .hidden)
    }
}
