import Foundation
import SaylarkCore

/// A scripted pill session for review: events on a timeline, the voice that drives the visual, the
/// screen behind it, and the frames worth a still. One or more lanes, each a pill with its own theme,
/// all driven by the same events (used to compare visuals and accents side by side).
public struct PillScenario: Sendable {
    public struct Lane: Sendable {
        public var label: String?
        public var theme: PillTheme
        /// The mic's name in the no-signal sentence.
        public var micName: String?
    }

    public var name: String
    public var title: String
    public var backdrop: Backdrop
    public var duration: Double
    public var events: [TimedPillEvent]
    /// The voice on the scenario's own timeline (time 0 = scenario start).
    public var voice: VoiceEnvelope
    public var lanes: [Lane]
    /// Times for the contact sheet, with a short caption each.
    public var keyframes: [(time: Double, caption: String)]
    /// Slow-motion copy is useful for short scenes only.
    public var slowMotion = true
    /// Mouse down (a button) and up (nil) on the pill, for the pressed look. Sorted by time.
    public var presses: [(time: Double, hit: PillHit?)] = []
}

/// The review scenarios. Each needs a few envelopes from data/envelopes.
public enum PillScenarios {
    public static func all(_ env: [String: VoiceEnvelope]) -> [PillScenario] {
        [holdShort(env), handsFree(env), noSignal(env), noField(env), noField(env, dark: true), cancel(env), interrupted(env), error(env),
         modelLoading(env), holdShort(env, reduce: true), cancel(env, reduce: true),
         cardCopy(env), cardCopy(env, dark: true),
         cardReason(env, .accessibilityOff), cardReason(env, .accessibilityOff, dark: true),
         cardReason(env, .clipboardNotAllowed), cardReason(env, .clipboardNotAllowed, dark: true),
         notice(env, .clipboardAccessOff), notice(env, .pasteFailed, dark: true),
         notice(env, .transcriptionFailed),
         compareVisuals(env),
         compareAccents(env, .chatLight), compareAccents(env, .editorDark), compareAccents(env, .wallpaper)]
            .compactMap { $0 } + m1(env) + cardClicks()
    }

    /// The card's buttons being clicked: the pressed look on mouse down and the pill's answer on
    /// the same frame. Needs no envelopes (the take is silent), so it renders on any checkout.
    public static func cardClicks() -> [PillScenario] {
        let text = "Can you check why the preview deploy failed and fix the environment variable name?"
        let t0 = 0.3, end = 1.3, hover = 2.0, click = 3.0, up = click + 0.12, focus = click + 1.6
        let copied = PillScenario(
            name: "card-copied", title: "No text field: copied for you, then paste on click",
            backdrop: .chatLight, duration: focus + 0.8,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.noTextFieldCopied(text))),
                     TimedPillEvent(hover, .hover(true)), TimedPillEvent(click, .pasteWhenFocused), TimedPillEvent(focus, .fieldFocused)],
            voice: track(focus + 0.8, []), lanes: [.init(theme: PillTheme())],
            keyframes: [(end + 0.05, "release +50 ms"), (end + 0.2, "+200 ms"), (end + 1.2, "card: copied"),
                        (click - frame, "before the click"), (click + frame, "mouse down +1 frame"), (click + 0.08, "+80 ms"),
                        (click + 0.4, "waiting"), (focus + 0.05, "field clicked")],
            slowMotion: false, presses: [(click, .pasteWhenFocused), (up, nil)])
        let copy = PillScenario(
            name: "card-copy-click", title: "Copy setting off: Copy clicked",
            backdrop: .editorDark, duration: click + 1.6,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.noTextField(text))),
                     TimedPillEvent(hover, .hover(true)), TimedPillEvent(click, .copied)],
            voice: track(click + 1.6, []), lanes: [.init(theme: PillTheme())],
            keyframes: [(end + 0.1, "release +100 ms"), (click - frame, "before the click"), (click + frame, "mouse down +1 frame"),
                        (click + 0.05, "+50 ms"), (click + 0.12, "+120 ms"), (click + 0.6, "Copied")],
            slowMotion: false, presses: [(click, .copy), (up, nil)])
        return [copied, copy]
    }

    /// Each voice visual with live words on (an opt-in setting; the default is Seeds with no
    /// words), hold to talk.
    public static func m1(_ env: [String: VoiceEnvelope]) -> [PillScenario] {
        var out: [PillScenario] = []
        if let clip = env["1ddab0d6"] {
            let t0 = 0.5, end = t0 + clip.duration
            for (kind, backdrop) in zip(VoiceVisualKind.allCases, [Backdrop.chatLight, .editorDark, .wallpaper]) {
                out.append(PillScenario(
                    name: "m1-live-words-\(kind.rawValue)", title: "\(kind.rawValue.capitalized) with live words, hold to talk",
                    backdrop: backdrop, duration: end + 0.6,
                    events: [TimedPillEvent(t0, .listen)] + wordEvents(clip, start: t0) + [TimedPillEvent(end, .finish(.inserted))],
                    voice: track(end + 0.6, [(t0, clip)]),
                    lanes: [.init(theme: PillTheme(visual: kind, liveWords: true))],
                    keyframes: [(t0 + frame, "Fn down +1 frame"), (t0 + 0.1, "+100 ms"), (t0 + 0.9, "first words")]
                        + stride(from: t0 + 1.8, to: end - 0.2, by: 1.2).map { ($0, String(format: "%.1f s", $0 - t0)) }
                        + [(end + 0.06, "release +60 ms")],
                    slowMotion: false))
            }
        }
        return out
    }

    static let frame = 1.0 / 120

    static func holdShort(_ env: [String: VoiceEnvelope], reduce: Bool = false) -> PillScenario? {
        guard let clip = env["0b8cbc84"] else { return nil }
        let t0 = 0.5, end = t0 + clip.duration
        return PillScenario(
            name: reduce ? "hold-short-reduced-motion" : "hold-short",
            title: reduce ? "Hold to talk, Reduce Motion on" : "Hold to talk, short take",
            backdrop: .chatLight, duration: end + 0.7,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.inserted))],
            voice: track(end + 0.7, [(t0, clip)]),
            lanes: [.init(theme: PillTheme(reduceMotion: reduce))],
            keyframes: [(t0 + frame, "Fn down +1 frame"), (t0 + 0.05, "+50 ms"), (t0 + 0.1, "+100 ms"), (t0 + 0.15, "+150 ms"),
                        (t0 + 1.2, "talking"), (t0 + 2.2, "talking"), (end + 0.04, "release +40 ms"), (end + 0.08, "+80 ms"),
                        (end + 0.12, "+120 ms")])
    }

    static func handsFree(_ env: [String: VoiceEnvelope]) -> PillScenario? {
        guard let clip = env["7150c599"] else { return nil }
        let t0 = 0.5, lock = 0.8, end = t0 + 20
        let cut = clip.trimmed(to: 20)
        var events = [TimedPillEvent(t0, .listen), TimedPillEvent(lock, .lockHandsFree)]
        events += wordEvents(cut, start: t0)
        events.append(TimedPillEvent(end, .finish(.inserted)))
        return PillScenario(
            name: "hands-free", title: "Hands-free, 20 s with live words", backdrop: .chatDark, duration: end + 0.8,
            events: events, voice: track(end + 0.8, [(t0, cut)]),
            lanes: [.init(theme: PillTheme(liveWords: true))],
            keyframes: [(t0 + frame, "Fn down +1 frame"), (lock + 0.05, "double-tap: hands-free"), (lock + 0.3, "+300 ms"),
                        (2.5, "first words"), (6, "6 s"), (11, "11 s"), (16.5, "16.5 s"), (end - 0.1, "20 s"),
                        (end + 0.05, "stop +50 ms"), (end + 0.12, "+120 ms")],
            slowMotion: false)
    }

    static func noSignal(_ env: [String: VoiceEnvelope]) -> PillScenario? {
        guard let clip = env["6ebe302d"] else { return nil }
        let t0 = 0.5, back = 5.2, end = back + clip.duration + 0.2
        // A dead input (digital silence) until 5.2 s, then the voice comes back.
        var voice = track(end + 0.7, [(back, clip)], floorDB: -60)
        voice.silence(from: 0, to: back)
        return PillScenario(
            name: "no-signal", title: "No signal, then the voice comes back", backdrop: .wallpaper, duration: end + 0.7,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.inserted))],
            voice: voice, lanes: [.init(theme: PillTheme(), micName: AudioInputs.pillName("MacBook Pro Microphone"))],
            keyframes: [(t0 + 0.2, "listening, silent"), (t0 + 1.9, "1.9 s"), (t0 + 2.05, "2 s: no signal"), (t0 + 2.2, "+150 ms"),
                        (t0 + 2.5, "+500 ms"), (4.5, "4.5 s"), (back + 0.15, "voice back"), (back + 0.5, "+500 ms"), (end + 0.05, "release")],
            slowMotion: false)
    }

    static func noField(_ env: [String: VoiceEnvelope], dark: Bool = false) -> PillScenario? {
        guard let clip = env["6ebe302d"] else { return nil }
        let t0 = 0.5, end = t0 + clip.duration, paste = end + 3.0, focus = paste + 2.2
        return PillScenario(
            name: dark ? "no-text-field-dark" : "no-text-field", title: "No text field: card, then paste on click",
            backdrop: dark ? .editorDark : .chatLight, duration: focus + 0.8,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.noTextField(clip.text ?? "Copied text"))),
                     TimedPillEvent(end + 1.2, .hover(true)), TimedPillEvent(end + 2.4, .hover(false)),
                     TimedPillEvent(paste, .pasteWhenFocused), TimedPillEvent(focus, .fieldFocused)],
            voice: track(focus + 0.8, [(t0, clip)]), lanes: [.init(theme: PillTheme())],
            keyframes: [(end - 0.3, "talking"), (end + 0.04, "release +40 ms"), (end + 0.1, "+100 ms"), (end + 0.2, "+200 ms"),
                        (end + 0.4, "+400 ms"), (end + 2.0, "card"), (paste + 0.08, "paste on click +80 ms"), (paste + 0.4, "+400 ms"),
                        (focus - 0.3, "waiting"), (focus + 0.05, "field clicked +50 ms")],
            slowMotion: false)
    }

    static func cancel(_ env: [String: VoiceEnvelope], reduce: Bool = false) -> PillScenario? {
        guard let clip = env["1ddab0d6"] else { return nil }
        let t0 = 0.5, esc = 2.2
        return PillScenario(
            name: reduce ? "cancel-reduced-motion" : "cancel", title: reduce ? "Esc, Reduce Motion on" : "Esc cancels",
            backdrop: .editorDark, duration: esc + 1.0,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(esc, .cancel)],
            voice: track(esc + 1.0, [(t0, clip)]), lanes: [.init(theme: PillTheme(reduceMotion: reduce))],
            keyframes: [(esc - 0.1, "talking"), (esc + 0.02, "Esc +20 ms"), (esc + 0.04, "+40 ms"), (esc + 0.07, "+70 ms"),
                        (esc + 0.1, "+100 ms"), (esc + 0.15, "+150 ms"), (esc + 0.25, "+250 ms"), (esc + 0.35, "+350 ms")])
    }

    static func interrupted(_ env: [String: VoiceEnvelope]) -> PillScenario? {
        guard let a = env["c6915b41"], let b = env["b3e4116a"] else { return nil }
        let t0 = 0.5, release = t0 + a.duration + 0.05, again = release + 0.05, end = again + b.duration
        return PillScenario(
            name: "interrupted", title: "Fn pressed again 50 ms into the dismiss", backdrop: .chatLight, duration: end + 0.7,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(release, .finish(.inserted)),
                     TimedPillEvent(again, .listen), TimedPillEvent(end, .finish(.inserted))],
            voice: track(end + 0.7, [(t0, a), (again, b)]), lanes: [.init(theme: PillTheme())],
            keyframes: [(release - 0.02, "before release"), (release + 0.025, "dismissing +25 ms"), (again, "Fn again (+50 ms)"),
                        (again + 0.025, "+25 ms"), (again + 0.05, "+50 ms"), (again + 0.1, "+100 ms"), (again + 0.2, "+200 ms"), (again + 0.6, "talking")])
    }

    static func error(_ env: [String: VoiceEnvelope]) -> PillScenario? {
        let t0 = 0.5, dismiss = 4.0
        return PillScenario(
            name: "error", title: "Error: microphone access off", backdrop: .wallpaper, duration: dismiss + 0.7,
            events: [TimedPillEvent(t0, .fail(.microphoneAccessOff)), TimedPillEvent(dismiss, .dismiss)],
            voice: track(dismiss + 0.7, []), lanes: [.init(theme: PillTheme())],
            keyframes: [(t0 + frame, "+1 frame"), (t0 + 0.06, "+60 ms"), (t0 + 0.15, "+150 ms"), (t0 + 1, "notice"),
                        (dismiss + 0.04, "dismiss +40 ms"), (dismiss + 0.1, "+100 ms")])
    }

    /// Fn pressed while the speech model is still loading: the engine sends `.modelNotReady`.
    static func modelLoading(_ env: [String: VoiceEnvelope]) -> PillScenario? {
        let t0 = 0.5, dismiss = 3.0
        return PillScenario(
            name: "model-loading", title: "Fn pressed while the speech model loads", backdrop: .chatLight, duration: dismiss + 0.7,
            events: [TimedPillEvent(t0, .fail(.modelNotReady(message: "Downloading the speech model, 42%."))), TimedPillEvent(dismiss, .dismiss)],
            voice: track(dismiss + 0.7, []),
            lanes: [.init(theme: PillTheme())],
            keyframes: [(t0 + frame, "+1 frame"), (t0 + 0.15, "+150 ms"), (t0 + 1, "notice"), (dismiss + 0.1, "dismiss +100 ms")])
    }

    /// The card after a take with no text field: Copy, then the "Copied" confirmation.
    static func cardCopy(_ env: [String: VoiceEnvelope], dark: Bool = false) -> PillScenario? {
        guard let clip = env["1ddab0d6"] else { return nil }
        let t0 = 0.5, end = t0 + clip.duration, copy = end + 2.4
        let text = clip.text ?? "Can you check why the preview deploy failed and fix the environment variable name?"
        return PillScenario(
            name: dark ? "card-copy-dark" : "card-copy", title: "Card, then Copy", backdrop: dark ? .editorDark : .chatLight,
            duration: copy + 1.9,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.noTextField(text))),
                     TimedPillEvent(end + 1.0, .hover(true)), TimedPillEvent(copy, .copied)],
            voice: track(copy + 1.9, [(t0, clip)]), lanes: [.init(theme: PillTheme())],
            keyframes: [(end + 0.1, "card opens"), (end + 0.5, "+500 ms"), (end + 2.0, "hover"), (copy + 0.1, "Copy"),
                        (copy + 0.7, "Copied"), (copy + 1.7, "gone")],
            slowMotion: false)
    }

    /// The card when pasting is not possible: the reason and its button sit above the actions.
    static func cardReason(_ env: [String: VoiceEnvelope], _ reason: CardReason, dark: Bool = false) -> PillScenario? {
        guard let clip = env["0b8cbc84"] else { return nil }
        let t0 = 0.5, end = t0 + clip.duration
        let name = reason == .accessibilityOff ? "card-no-accessibility" : "card-clipboard-off"
        return PillScenario(
            name: dark ? name + "-dark" : name, title: "Card: " + reason.sentence, backdrop: dark ? .editorDark : .chatLight,
            duration: end + 2.4,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.cannotPaste(clip.text ?? "A short take that could not be pasted.", reason: reason)))],
            voice: track(end + 2.4, [(t0, clip)]), lanes: [.init(theme: PillTheme())],
            keyframes: [(end + 0.15, "card opens"), (end + 0.6, "+600 ms"), (end + 2.0, "card")],
            slowMotion: false)
    }

    /// A notice with one action: clipboard off, paste failed, transcription failed.
    static func notice(_ env: [String: VoiceEnvelope], _ error: PillError, dark: Bool = false) -> PillScenario? {
        let t0 = 0.5, dismiss = 4.0
        let name: String
        switch error {
        case .clipboardAccessOff: name = "error-clipboard-off"
        case .pasteFailed: name = "error-paste-failed"
        default: name = "error-transcription-failed"
        }
        return PillScenario(
            name: name, title: "Notice: " + error.message, backdrop: dark ? .editorDark : .chatLight, duration: dismiss + 0.7,
            events: [TimedPillEvent(t0, .fail(error)), TimedPillEvent(dismiss, .dismiss)],
            voice: track(dismiss + 0.7, []), lanes: [.init(theme: PillTheme())],
            keyframes: [(t0 + 0.15, "+150 ms"), (t0 + 1.2, "notice"), (dismiss + 0.1, "dismiss +100 ms")],
            slowMotion: false)
    }

    static func compareVisuals(_ env: [String: VoiceEnvelope]) -> PillScenario? {
        guard let clip = env["1ddab0d6"] else { return nil }
        let t0 = 0.5, end = t0 + clip.duration
        return PillScenario(
            name: "compare-visuals", title: "Voice visuals: trace, wave, seeds", backdrop: .chatDark, duration: end + 0.6,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.inserted))],
            voice: track(end + 0.6, [(t0, clip)]),
            lanes: VoiceVisualKind.allCases.map { .init(label: $0.rawValue.capitalized, theme: PillTheme(visual: $0)) },
            keyframes: stride(from: t0 + 0.6, to: end, by: 0.45).map { ($0, String(format: "%.2f s", $0)) },
            slowMotion: false)
    }

    static func compareAccents(_ env: [String: VoiceEnvelope], _ backdrop: Backdrop) -> PillScenario? {
        guard let clip = env["0b8cbc84"] else { return nil }
        let t0 = 0.5, end = t0 + clip.duration
        return PillScenario(
            name: "compare-accents-\(backdrop.rawValue)", title: "Accent options over \(backdrop.rawValue)", backdrop: backdrop,
            duration: end + 0.6,
            events: [TimedPillEvent(t0, .listen), TimedPillEvent(end, .finish(.inserted))],
            voice: track(end + 0.6, [(t0, clip)]),
            lanes: PillAccent.allCases.map { .init(label: $0.rawValue.capitalized, theme: PillTheme(accent: $0)) },
            keyframes: [(t0 + 0.9, "talking"), (t0 + 1.6, "talking"), (t0 + 2.3, "talking")],
            slowMotion: false)
    }

    // MARK: - Helpers

    /// Builds a voice track: room tone at `floorDB` with clips placed at the given times.
    static func track(_ seconds: Double, _ clips: [(Double, VoiceEnvelope)], floorDB: Double = -64) -> VoiceEnvelope {
        let rate = 120.0
        let n = Int(seconds * rate) + 1
        // Room tone with a little slow, deterministic wobble, like a real quiet room.
        var rms = (0..<n).map { i -> Float in
            let t = Double(i) / rate
            return Float(pow(10, (floorDB + 1.5 * sin(t * 7.3) + 1.0 * sin(t * 2.1 + 1)) / 20))
        }
        var peak = rms.map { $0 * 2.2 }
        for (start, clip) in clips {
            let off = Int(start * rate)
            for i in clip.rms.indices where off + i < n {
                rms[off + i] = max(rms[off + i], clip.rms[i])
                peak[off + i] = max(peak[off + i], clip.peak[i])
            }
        }
        return VoiceEnvelope(id: "track", rate: rate, rms: rms, peak: peak)
    }

    /// Fakes live words: each word appears once its share of the voiced audio has been heard, plus a
    /// short recognition delay. Word timings from the engine replace this in M1.
    static func wordEvents(_ clip: VoiceEnvelope, start: Double, lag: Double = 0.35) -> [TimedPillEvent] {
        let words = (clip.text ?? "").split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let voiced = clip.rms.map { $0.dBFS > -42 ? 1.0 : 0.0 }
        let total = max(1, voiced.reduce(0, +))
        var events: [TimedPillEvent] = []
        var acc = 0.0, shown = 0
        for (i, v) in voiced.enumerated() {
            acc += v
            // Recognition arrives in small bursts, not one word per frame.
            guard i % 24 == 0 else { continue }
            let due = min(words.count, Int(Double(words.count) * acc / total))
            if due > shown {
                shown = due
                events.append(TimedPillEvent(start + Double(i) / clip.rate + lag, .words(Array(words.prefix(due)))))
            }
        }
        return events
    }
}

extension VoiceEnvelope {
    /// The first `seconds` of the clip, with the transcript cut in proportion (lab use only).
    func trimmed(to seconds: Double) -> VoiceEnvelope {
        let n = min(rms.count, Int(seconds * rate))
        var e = VoiceEnvelope(id: id, rate: rate, rms: Array(rms.prefix(n)), peak: Array(peak.prefix(n)), text: text)
        if let text, n < rms.count {
            let words = text.split(separator: " ")
            e.text = words.prefix(Int(Double(words.count) * Double(n) / Double(rms.count))).joined(separator: " ")
        }
        return e
    }

    /// Digital silence between two times, like a muted or dead input.
    mutating func silence(from a: Double, to b: Double) {
        for i in Int(a * rate)..<min(rms.count, Int(b * rate)) {
            rms[i] = 0
            peak[i] = 0
        }
    }
}
