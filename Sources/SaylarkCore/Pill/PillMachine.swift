import Foundation

/// Steps a `PillState` through events and time. Deterministic: the same events at the same times
/// always give the same states, which is what the lab, the renderer and the tests rely on.
public struct PillMachine: Sendable {
    public private(set) var state = PillState()
    public var config: PillConfig

    public init(config: PillConfig = PillConfig()) {
        self.config = config
    }

    /// Applies one event. Events that make no sense in the current phase are ignored.
    ///
    /// `take` is the take the event came from. `.listen` with a take makes it the current take; any
    /// other event from a different take is dropped, so a late finish from an earlier take can't
    /// close this take's pill. Events with no take (the pill's own buttons, the lab) always apply.
    public mutating func handle(_ event: PillEvent, take: UUID? = nil, at time: Double) {
        if let take, event != .listen, take != state.take { return }
        switch event {
        case .listen:
            // A new take always wins, including over a dismissal still on screen.
            state.take = take
            state.mode = .hold
            state.takeStart = time
            state.lastHeard = time
            state.words = []
            state.wordCount = 0
            state.noSignal = false
            state.cardReason = nil
            state.cardCopied = false
            enter(.listening, at: time)

        case .lockHandsFree:
            guard state.phase == .listening else { return }
            state.mode = .handsFree

        case .finish(let outcome):
            guard state.phase == .listening else { return }
            switch outcome {
            case .inserted, .empty: enter(.done, at: time)
            case .noTextField(let text):
                state.cardReason = nil
                state.cardCopied = false
                enter(.card(text: text), at: time)
            case .noTextFieldCopied(let text):
                state.cardReason = nil
                state.cardCopied = true
                enter(.card(text: text), at: time)
            case .cannotPaste(let text, let reason):
                state.cardReason = reason
                state.cardCopied = false
                enter(.card(text: text), at: time)
            }

        case .cancel:
            guard state.phase == .listening else { return }
            enter(.cancelled, at: time)

        case .words(let words):
            guard state.phase == .listening else { return }
            state.words = Array(words.suffix(config.maxWords))
            state.wordCount = words.count

        case .fail(let error):
            enter(.error(error), at: time)

        case .pasteWhenFocused:
            // With a reason on the card, a paste could not happen later either.
            guard case .card(let text) = state.phase, state.cardReason == nil else { return }
            enter(.waitingForField(text: text), at: time)

        case .copied:
            guard case .card = state.phase else { return }
            enter(.copied, at: time)

        case .dismiss:
            switch state.phase {
            case .card, .waitingForField, .error, .copied: enter(.hidden, at: time)
            default: return
            }

        case .fieldFocused:
            guard case .waitingForField = state.phase else { return }
            enter(.done, at: time)

        case .hover(let inside):
            if state.hovering && !inside { state.hoverEnded = time }
            state.hovering = inside
        }
    }

    /// Advances time. `peakDB` is the mic's peak level for the latest frame, or nil when there is no
    /// level (not listening).
    public mutating func tick(at time: Double, peakDB: Double?) {
        let inPhase = time - state.phaseStart
        switch state.phase {
        case .listening:
            if let peakDB, peakDB > config.noSignalFloorDB { state.lastHeard = time }
            state.noSignal = time - state.lastHeard >= config.noSignalAfter
        case .done:
            if inPhase >= config.doneHold { enter(.hidden, at: time) }
        case .cancelled:
            if inPhase >= config.cancelHold { enter(.hidden, at: time) }
        case .card:
            if !state.hovering, time - max(state.phaseStart, state.hoverEnded) >= config.cardTimeout {
                enter(.hidden, at: time)
            }
        case .error:
            if !state.hovering, time - max(state.phaseStart, state.hoverEnded) >= config.errorTimeout {
                enter(.hidden, at: time)
            }
        case .copied:
            if inPhase >= config.copiedHold { enter(.hidden, at: time) }
        case .hidden, .waitingForField:
            break
        }
    }

    private mutating func enter(_ phase: PillPhase, at time: Double) {
        state.phase = phase
        state.phaseStart = time
        if phase != .listening { state.noSignal = false }
        switch phase {
        case .card, .waitingForField, .copied: break
        default: state.cardReason = nil; state.cardCopied = false
        }
    }
}
