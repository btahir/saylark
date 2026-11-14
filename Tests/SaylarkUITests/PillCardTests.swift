import Foundation
import Testing
import SaylarkCore

/// The card: nothing is copied for the user; Copy, paste on the next field, or Dismiss.
@Suite struct PillCardFlowTests {
    private func cardMachine(reason: CardReason? = nil) -> PillMachine {
        var m = PillMachine()
        m.handle(.listen, at: 0)
        if let reason {
            m.handle(.finish(.cannotPaste("hello", reason: reason)), at: 1)
        } else {
            m.handle(.finish(.noTextField("hello")), at: 1)
        }
        return m
    }

    @Test func copyShowsConfirmationThenCloses() {
        var m = cardMachine()
        m.handle(.copied, at: 2)
        #expect(m.state.phase == .copied)
        m.tick(at: 2.5, peakDB: nil)
        #expect(m.state.phase == .copied)
        m.tick(at: 2 + m.config.copiedHold + 0.01, peakDB: nil)
        #expect(m.state.phase == .hidden)
    }

    @Test func copiedIsIgnoredOutsideTheCard() {
        var m = PillMachine()
        m.handle(.copied, at: 0)
        #expect(m.state.phase == .hidden)
        m.handle(.listen, at: 1)
        m.handle(.copied, at: 1.1)
        #expect(m.state.phase == .listening)
    }

    @Test func waitingCanBeCancelled() {
        var m = cardMachine()
        m.handle(.pasteWhenFocused, at: 2)
        #expect(m.state.phase == .waitingForField(text: "hello"))
        m.handle(.dismiss, at: 3)
        #expect(m.state.phase == .hidden)
    }

    @Test func reasonIsKeptOnTheCardAndBlocksPasteWhenFocused() {
        var m = cardMachine(reason: .accessibilityOff)
        #expect(m.state.cardReason == .accessibilityOff)
        m.handle(.pasteWhenFocused, at: 2)
        #expect(m.state.phase == .card(text: "hello"), "no paste later either")
        m.handle(.copied, at: 3)
        #expect(m.state.phase == .copied)
        m.tick(at: 10, peakDB: nil)
        #expect(m.state.cardReason == nil)
    }

    @Test func plainCardHasNoReasonAndNewTakeClearsIt() {
        var m = cardMachine(reason: .clipboardNotAllowed)
        m.handle(.listen, at: 5)
        #expect(m.state.cardReason == nil)
        m.handle(.finish(.noTextField("x")), at: 6)
        #expect(m.state.cardReason == nil)
    }

    @Test func newErrorsHaveOneSentenceAndAtMostOneAction() {
        #expect(PillError.modelNotReady(message: "Still getting ready.").message == "Still getting ready.")
        #expect(PillError.modelNotReady(message: "x").actionTitle == nil)
        #expect(PillError.clipboardAccessOff.actionTitle == "Allow")
        #expect(PillError.pasteFailed.actionTitle == "Open Library")
        var m = PillMachine()
        m.handle(.fail(.modelNotReady(message: "Preparing, 40%.")), at: 0)
        #expect(m.state.phase == .error(.modelNotReady(message: "Preparing, 40%.")))
    }

    @Test func eventFromAnotherTakeCannotCloseTheCard() {
        var m = PillMachine()
        let a = UUID(), b = UUID()
        m.handle(.listen, take: a, at: 0)
        m.handle(.finish(.noTextField("t")), take: a, at: 1)
        m.handle(.copied, take: b, at: 2)
        #expect(m.state.phase == .card(text: "t"))
    }
}
