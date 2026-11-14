import AppKit
import QuartzCore
import SaylarkCore

/// What a click on the pill hit.
public enum PillHit: Sendable, Equatable {
    case stop, pasteWhenFocused, dismiss, errorAction
    /// Card: Copy.
    case copy
    /// Card: the button that fixes the reason the text could not be pasted.
    case reasonAction
}

/// The pill as a Core Animation layer tree, updated once per display frame from a `PillState`.
///
/// Every animated value is a `Spring` stepped here, and layer properties are set directly with
/// implicit actions off. So the model layer always equals what is on screen, which means the same
/// code renders live (display link) and offscreen (CARenderer, frame by frame), and any change can
/// retarget mid-flight without a jump.
@MainActor public final class PillView {
    /// Root layer. Its bounds are the fixed canvas; the pill sits at the bottom centre.
    public let layer = CALayer()
    public static let canvasSize = CGSize(width: 420, height: 200)

    public var theme: PillTheme {
        didSet { if theme.visual != oldValue.visual { rebuildVisual() } }
    }
    public var config = PillConfig()

    private var images: TextImages
    private var scale: CGFloat
    /// The pixel density the text bitmaps are drawn for.
    public var backingScale: CGFloat { scale }

    // Layers
    private let pill = CALayer()          // positioned + scaled + faded as one
    private let shadow = CALayer()
    private let body = CALayer()
    private var visual: any VoiceVisual
    private let visualHost = CALayer()
    private let timeLabel = CALayer()
    private let stopButton = CALayer()
    private let stopGlyph = CALayer()
    private let message = CALayer()
    private let wordsClip = CALayer()
    private let wordsStrip = CALayer()
    private let wordsFade = CAGradientLayer()
    private let noticeIcon = CALayer()
    private let noticeText = CALayer()
    private let noticeButton = CALayer()
    private let noticeButtonText = CALayer()
    private let closeGlyph = CALayer()
    private let cardText = CALayer()
    private let reasonIcon = CALayer()
    private let reasonText = CALayer()
    private let reasonButton = CALayer()
    private let reasonButtonText = CALayer()
    private let copyButton = CALayer()
    private let copyText = CALayer()
    private let pasteButton = CALayer()
    private let pasteText = CALayer()
    private let dismissButton = CALayer()
    private let dismissText = CALayer()

    /// Every animated value. Stepped together once per frame.
    private struct Motion {
        var presence = Spring(0, params: PillSprings.fadeIn)
        var scaleS = Spring(1, params: PillSprings.appear)
        var width = Spring(PillMetrics.holdWidth, params: PillSprings.morph)
        var height = Spring(PillMetrics.height, params: PillSprings.morph)
        var shake = Spring(0, params: PillSprings.shake)
        var tint = Spring(1, params: PillSprings.tint)
        var visualW = Spring(PillMetrics.visualWidthHold, params: PillSprings.morph)
        var aVisual = Spring(0, params: PillSprings.content)
        var aTime = Spring(0, params: PillSprings.content)
        var aMessage = Spring(0, params: PillSprings.content)
        var aWords = Spring(0, params: PillSprings.content)
        var aNotice = Spring(0, params: PillSprings.content)
        var aCard = Spring(0, params: PillSprings.content)
        var scroll = Spring(0, params: PillSprings.scroll)

        mutating func step(_ dt: Double) {
            presence.step(dt); scaleS.step(dt); width.step(dt); height.step(dt); shake.step(dt)
            tint.step(dt); visualW.step(dt); scroll.step(dt)
            aVisual.step(dt); aTime.step(dt); aMessage.step(dt); aWords.step(dt); aNotice.step(dt); aCard.step(dt)
        }

        mutating func setContentParams(_ p: SpringParams) {
            aVisual.params = p; aTime.params = p; aMessage.params = p; aWords.params = p; aNotice.params = p; aCard.params = p
        }
    }
    private var mo = Motion()

    // Live words: absolute index → layer, x in the strip, fade-in spring.
    private struct Word { let layer: CALayer; let x: CGFloat; let width: CGFloat; var alpha: Spring }
    private var words: [Int: Word] = [:]
    private var wordsEnd: CGFloat = 0
    private var lastWordIndex = -1

    private var meter = LevelMeter()
    private(set) var history = LevelHistory()
    private var phaseKey = ""
    private var phaseStart = -1.0
    private var cardSize = CGSize(width: PillMetrics.cardWidth, height: 100)
    /// Current hit areas, in root coordinates. Taken from the settled layout (where the pill is
    /// going), not the animated one, so a button takes clicks from the frame it is decided on.
    private var hits: [(CGRect, PillHit)] = []
    /// The button held down, for the pressed look, and how pressed it looks (0...1).
    private var pressedLayer: CALayer?
    private var press = Spring(0, params: SpringParams(response: 0.1, damping: 1))

    public init(theme: PillTheme = PillTheme(), scale: CGFloat = 2) {
        self.theme = theme
        self.scale = scale
        images = TextImages(scale: scale)
        visual = makeVoiceVisual(theme.visual)
        build()
        prewarm()
    }

    /// Renders every fixed string once, so the first frame that needs one doesn't pay for it.
    private func prewarm() {
        let m = PillMetrics.self
        _ = messageImage
        for s in 0..<180 { _ = timeImage(for: Double(s)) }
        _ = noticeWidth(icon: nil, text: Self.waitingText, button: Self.waitingButton)
        _ = noticeWidth(icon: "checkmark", text: "Copied", button: nil, close: false)
        for e in [PillError.microphoneAccessOff, .accessibilityOff, .microphoneMissing(name: config.micName),
                  .clipboardAccessOff, .pasteFailed, .transcriptionFailed] {
            _ = noticeWidth(icon: e.symbol, text: e.message, button: e.actionTitle)
        }
        _ = images.line("Paste when I click a field", size: m.smallSize, weight: .semibold, color: m.ink)
        _ = images.line("Copy", size: m.smallSize, weight: .medium, color: m.primary)
        _ = images.line("Copy", size: m.smallSize, weight: .semibold, color: m.ink)
        _ = images.line("Dismiss", size: m.smallSize, weight: .medium, color: m.primary)
        _ = images.line(Self.copiedNote, size: m.smallSize, weight: .medium, color: m.secondary)
        _ = images.line(Self.noFieldNote, size: m.smallSize, weight: .medium, color: m.secondary)
        _ = images.symbol("checkmark", size: 11, weight: .semibold, color: m.secondary)
        _ = images.line(" ", size: m.bodySize, color: m.primary)
        _ = images.symbol("xmark", size: 9, weight: .bold, color: m.secondary)
    }

    /// True once the pill is hidden and every spring has settled: the display link can stop.
    public private(set) var isIdle = true

    /// The pill's frame in root coordinates (before scale), for hit tests and panel placement.
    public private(set) var pillFrame: CGRect = .zero

    public func hit(_ point: CGPoint) -> PillHit? {
        hits.first { $0.0.contains(point) }?.1
    }

    /// Where `hit` takes clicks now (root coordinates), or nil when it is not on the pill.
    public func hitRect(_ hit: PillHit) -> CGRect? {
        hits.first { $0.1 == hit }?.0
    }

    /// The settled pill, in root coordinates, while it has something to click; nil otherwise. The
    /// panel takes clicks over exactly this area and lets every other click through.
    public private(set) var clickZone: CGRect?

    /// Shows `hit`'s button pressed (mouse down), or lets it go (nil, mouse up). The pressed look is
    /// on the next frame; it fades out after the release.
    public func setPressed(_ hit: PillHit?) {
        guard let hit else { press.target = 0; return }
        pressedLayer = layer(for: hit)
        press.snap(to: 1)
    }

    /// How pressed `hit`'s button looks, 0...1 (tests and renders).
    public func pressAmount(_ hit: PillHit) -> Double {
        guard let l = pressedLayer, l === layer(for: hit) else { return 0 }
        return press.value
    }

    private func layer(for hit: PillHit) -> CALayer {
        switch hit {
        case .stop: stopButton
        case .copy: copyButton
        case .pasteWhenFocused: pasteButton
        case .reasonAction: reasonButton
        case .errorAction: noticeButton
        case .dismiss: phaseKey == "card" ? dismissButton : noticeButton
        }
    }

    // MARK: - Frame update

    /// Steps every spring by `dt` and applies the result to the layers. `rms` is the mic's linear RMS
    /// for this frame (nil when not listening). Call once per display frame.
    public func update(state: PillState, time: Double, rms: Float?, dt: Double) {
        let reduce = theme.reduceMotion
        let level = rms.map { meter.update(rms: $0, dt: dt) } ?? meter.update(rms: 0, dt: dt)
        // Outside listening the history stops, so the visual freezes instead of draining away.
        if state.phase == .listening { history.push(level) }

        retarget(state: state, time: time, reduce: reduce)
        mo.step(dt)
        press.step(dt)
        if press.isSettled, press.value == 0 { pressedLayer = nil }
        for key in words.keys { words[key]!.alpha.step(dt) }

        apply(state: state, time: time)
        isIdle = state.phase == .hidden && mo.presence.value < 0.002 && mo.presence.isSettled
    }

    // MARK: - Targets

    private func retarget(state: PillState, time: Double, reduce: Bool) {
        let entered = state.phaseStart != phaseStart || state.phase.name != phaseKey
        let wasInvisible = mo.presence.value < 0.02
        phaseStart = state.phaseStart
        phaseKey = state.phase.name
        let p = state.phase
        let handsFree = state.mode == .handsFree
        let morph = reduce ? PillSprings.reduced : PillSprings.morph

        // Geometry
        var w = PillMetrics.holdWidth, h = PillMetrics.height
        var geo = morph
        switch p {
        case .listening:
            w = listeningWidth(state)
        case .done:
            // Keep the layout; the pill shrinks and fades as one object.
            w = mo.width.target; h = mo.height.target
        case .card(let text):
            cardSize = measureCard(text, reason: state.cardReason, copied: state.cardCopied)
            w = cardSize.width; h = cardSize.height
            geo = reduce ? PillSprings.reduced : PillSprings.card
        case .waitingForField:
            w = noticeWidth(icon: nil, text: Self.waitingText, button: Self.waitingButton)
        case .copied:
            w = noticeWidth(icon: "checkmark", text: "Copied", button: nil, close: false)
        case .error(let e):
            let n = errorNotice(e)
            w = noticeWidth(icon: n.icon, text: n.text, button: n.button)
        case .cancelled, .hidden:
            w = mo.width.target; h = mo.height.target
        }
        mo.width.params = geo; mo.height.params = geo
        mo.width.target = w; mo.height.target = h

        // Presence and scale
        let visible: Bool
        switch p {
        case .hidden, .done: visible = false
        case .cancelled: visible = time - state.phaseStart < 0.24 || reduce && time - state.phaseStart < 0.12
        default: visible = true
        }
        if visible {
            if wasInvisible && entered {
                // Appear: visible on the very first frame, then spring up.
                mo.width.snap(to: w); mo.height.snap(to: h)
                mo.visualW.snap(to: visualWidth(state))
                mo.presence.snap(to: reduce ? 0.35 : 0.5)
                mo.scaleS.snap(to: reduce ? 1 : 0.6)
                mo.tint.snap(to: 1)
                meter.reset(); history.reset()
                clearWords()
            }
            mo.presence.params = reduce ? PillSprings.reduced : PillSprings.fadeIn
            mo.scaleS.params = reduce ? PillSprings.reduced : PillSprings.appear
            mo.presence.target = 1
            mo.scaleS.target = 1
        } else {
            mo.presence.params = reduce ? PillSprings.reduced : PillSprings.exitFade
            mo.scaleS.params = reduce ? PillSprings.reduced : PillSprings.exit
            mo.presence.target = 0
            mo.scaleS.target = reduce ? 1 : (p == .done ? 0.86 : 0.92)
        }

        // A new take starts with nothing pressed.
        if entered, p == .listening { pressedLayer = nil; press.snap(to: 0) }

        // Esc: a short horizontal shake, kicked once on entry.
        if entered, p == .cancelled, !reduce { mo.shake.velocity = -PillSprings.shakeKick }
        mo.shake.target = 0

        // Content. While leaving (done, cancelled, hidden) the content holds still and goes out with
        // the pill, so nothing reflows on the way out.
        let listening = p == .listening
        let leaving = p == .done || p == .cancelled || p == .hidden
        if !leaving {
            mo.visualW.params = morph
            mo.visualW.target = visualWidth(state)
            mo.aVisual.target = listening ? 1 : 0
            mo.aTime.target = listening && handsFree ? 1 : 0
            mo.aMessage.target = listening && state.noSignal ? 1 : 0
            mo.aWords.target = listening && showsWords(state) ? 1 : 0
            switch p {
            case .waitingForField, .error, .copied: mo.aNotice.target = 1
            default: mo.aNotice.target = 0
            }
            if case .card = p { mo.aCard.target = 1 } else { mo.aCard.target = 0 }
        }
        if visible && wasInvisible && entered {
            for kp in [\Motion.aVisual, \.aTime, \.aMessage, \.aWords, \.aNotice, \.aCard] {
                mo[keyPath: kp].snap(to: mo[keyPath: kp].target)
            }
        }
        // Accent only while it is really listening to a voice. Esc drains it fast.
        let tintTarget: Double = listening && !state.noSignal ? 1 : 0
        mo.tint.params = p == .cancelled ? PillSprings.exit : tintTarget > mo.tint.value ? PillSprings.tintReturn : PillSprings.tint
        mo.tint.target = tintTarget

        if listening, theme.liveWords { syncWords(state) }
        mo.setContentParams(reduce ? PillSprings.reduced : PillSprings.content)
    }

    private func showsWords(_ s: PillState) -> Bool { theme.liveWords && !s.words.isEmpty && !s.noSignal }

    private func visualWidth(_ s: PillState) -> CGFloat {
        s.mode == .handsFree || s.noSignal || showsWords(s) ? PillMetrics.visualWidthCompact : PillMetrics.visualWidthHold
    }

    private func listeningWidth(_ s: PillState) -> CGFloat {
        let m = PillMetrics.self
        var w = m.padding + visualWidth(s)
        if s.noSignal {
            w += m.gap + messageImage.size.width
        } else if showsWords(s) {
            w += m.gap + m.wordsWidth
        }
        if s.mode == .handsFree {
            w += m.gap + timeImage(for: 0).size.width + 8 + m.buttonSize + m.buttonInset
        } else {
            w += m.padding
        }
        return w.rounded()
    }

    static let waitingText = "Will paste into the next field you click."
    static let waitingButton = "Cancel"
    static let cardLines = 4
    /// The card's note when no text field had focus and the text went on the clipboard.
    public static let copiedNote = "Copied. Press \u{2318}V to paste."
    /// The card's note when no text field had focus and auto-copy is off.
    public static let noFieldNote = "No text field was focused."

    /// An error phase shows the error's own sentence and action (or just a close button).
    private func errorNotice(_ e: PillError) -> (icon: String?, text: String, button: String?) {
        (e.symbol, e.message, e.actionTitle)
    }

    /// `close: false` leaves out the round close button (the "Copied" confirmation closes by itself).
    private func noticeWidth(icon: String?, text: String, button: String?, close: Bool = true) -> CGFloat {
        let m = PillMetrics.self
        let iconW = icon.map { images.symbol($0, size: 12, weight: .medium, color: m.secondary).size.width + 8 } ?? 0
        let textW = images.line(text, size: m.bodySize, weight: .medium, color: m.primary).size.width
        var w = m.padding + iconW + textW
        if let button {
            w += m.gap + images.line(button, size: m.smallSize, weight: .medium, color: m.primary).size.width + 24 + m.buttonInset
        } else if close {
            w += m.gap + m.buttonSize + m.buttonInset
        } else {
            w += m.padding
        }
        return w.rounded()
    }

    private static let reasonIndent: CGFloat = 20

    private func reasonButtonWidth(_ reason: CardReason) -> CGFloat {
        images.line(reason.actionTitle, size: PillMetrics.smallSize, weight: .medium, color: PillMetrics.primary).size.width + 22
    }

    private func reasonParagraph(_ reason: CardReason) -> TextImages.Rendered {
        let m = PillMetrics.self
        let width = m.cardWidth - 2 * m.cardPadding - Self.reasonIndent - reasonButtonWidth(reason) - 10
        return images.paragraph(reason.sentence, size: m.smallSize, width: width, maxLines: 2, color: m.primary)
    }

    /// Height of the line above the card's buttons: the reason and its fix, or "Copied".
    private func noteBlockHeight(_ reason: CardReason?, copied: Bool) -> CGFloat {
        if let reason { return max(reasonParagraph(reason).size.height, 24) }
        return max(noteImage(copied: copied).size.height, 18)
    }

    private func noteImage(copied: Bool) -> TextImages.Rendered {
        images.line(copied ? Self.copiedNote : Self.noFieldNote, size: PillMetrics.smallSize, weight: .medium, color: PillMetrics.secondary)
    }

    private func measureCard(_ text: String, reason: CardReason?, copied: Bool) -> CGSize {
        let m = PillMetrics.self
        let para = images.paragraph(text, size: m.bodySize, width: m.cardWidth - 2 * m.cardPadding, maxLines: Self.cardLines, color: m.primary)
        var h = 14 + para.size.height + 12 + m.cardButtonHeight + m.cardButtonInset
        let note = noteBlockHeight(reason, copied: copied && reason == nil)
        h += note + (reason == nil ? 8 : 12)
        return CGSize(width: m.cardWidth, height: h.rounded())
    }

    // MARK: - Button layout (shared by drawing and hit areas)

    private struct CardButton {
        let hit: PillHit
        let layer: CALayer
        let label: CALayer
        let image: TextImages.Rendered
        let frame: CGRect
    }

    /// The card's buttons for a card `width` wide, right to left: the main one, Copy (unless the
    /// text is already copied), then Dismiss. In pill-body coordinates.
    private func cardButtons(width: CGFloat, reason: CardReason?, copied: Bool) -> [CardButton] {
        let m = PillMetrics.self
        var right = width - m.cardButtonInset
        var out: [CardButton] = []
        func add(_ hit: PillHit, _ button: CALayer, _ label: CALayer, _ title: String, primary: Bool) {
            let img = images.line(title, size: m.smallSize, weight: primary ? .semibold : .medium, color: primary ? m.ink : m.primary)
            let bw = img.size.width + 26
            let frame = snap(CGRect(x: right - bw, y: m.cardButtonInset, width: bw, height: m.cardButtonHeight))
            out.append(CardButton(hit: hit, layer: button, label: label, image: img, frame: frame))
            right = frame.minX - 6
        }
        if reason == nil {
            add(.pasteWhenFocused, pasteButton, pasteText, "Paste when I click a field", primary: true)
            if !copied { add(.copy, copyButton, copyText, "Copy", primary: false) }
        } else {
            // Pasting later cannot work either, so Copy is the main action.
            add(.copy, copyButton, copyText, "Copy", primary: true)
        }
        add(.dismiss, dismissButton, dismissText, "Dismiss", primary: false)
        return out
    }

    private func reasonBlockY(_ reason: CardReason?) -> CGFloat {
        PillMetrics.cardButtonInset + PillMetrics.cardButtonHeight + (reason == nil ? 8 : 12)
    }

    private func reasonButtonFrame(width: CGFloat, reason: CardReason) -> CGRect {
        let bw = reasonButtonWidth(reason)
        let blockH = noteBlockHeight(reason, copied: false)
        return snap(CGRect(x: width - PillMetrics.cardPadding - bw, y: reasonBlockY(reason) + (blockH - 24) / 2, width: bw, height: 24))
    }

    /// The notice's one control: a titled button or the round close button, at the right end.
    private func noticeButtonFrame(width: CGFloat, button: String?) -> CGRect {
        let m = PillMetrics.self
        if let button {
            let bw = images.line(button, size: m.smallSize, weight: .medium, color: m.primary).size.width + 24
            return snap(CGRect(x: width - m.buttonInset - bw, y: m.buttonInset, width: bw, height: m.buttonSize))
        }
        return snap(CGRect(x: width - m.buttonInset - m.buttonSize, y: m.buttonInset, width: m.buttonSize, height: m.buttonSize))
    }

    private func stopFrame(width: CGFloat) -> CGRect {
        let m = PillMetrics.self
        return snap(CGRect(x: width - m.buttonInset - m.buttonSize, y: m.buttonInset, width: m.buttonSize, height: m.buttonSize))
    }

    /// Hit areas for `state` at the size the pill is going to (root coordinates). Independent of
    /// how far any animation has got, so a click lands where the button is going to be from the
    /// frame the state changes, and never falls through while content fades in.
    private func settledHits(_ state: PillState) -> (zone: CGRect?, hits: [(CGRect, PillHit)]) {
        let w = CGFloat(mo.width.target), h = CGFloat(mo.height.target)
        let zone = CGRect(x: ((Self.canvasSize.width - w) / 2).rounded(), y: PillMetrics.bottomInset, width: w, height: h)
        var out: [(CGRect, PillHit)] = []
        func add(_ r: CGRect, _ hit: PillHit) { out.append((r.offsetBy(dx: zone.minX, dy: zone.minY).insetBy(dx: -4, dy: -4), hit)) }
        switch state.phase {
        case .listening where state.mode == .handsFree:
            add(stopFrame(width: w), .stop)
        case .card:
            for b in cardButtons(width: w, reason: state.cardReason, copied: state.cardCopied && state.cardReason == nil) { add(b.frame, b.hit) }
            if let reason = state.cardReason { add(reasonButtonFrame(width: w, reason: reason), .reasonAction) }
        case .waitingForField:
            add(noticeButtonFrame(width: w, button: Self.waitingButton), .dismiss)
        case .error(let e):
            add(noticeButtonFrame(width: w, button: e.actionTitle), .errorAction)
        default:
            break
        }
        // While the pill has buttons, every click on it is the pill's, so a click just beside a
        // button never lands in the app behind.
        return (out.isEmpty ? nil : out.reduce(zone) { $0.union($1.0) }, out)
    }

    private var messageImage: TextImages.Rendered {
        images.line("Not hearing you. Check the \(config.micName).", size: PillMetrics.bodySize, weight: .medium, color: PillMetrics.secondary)
    }

    private func timeImage(for seconds: Double) -> TextImages.Rendered {
        let s = Int(seconds)
        return images.line(String(format: "%d:%02d", s / 60, s % 60), size: PillMetrics.bodySize, weight: .medium, color: PillMetrics.primary, monoDigits: true)
    }

    // MARK: - Live words

    private func syncWords(_ s: PillState) {
        let first = s.wordCount - s.words.count
        let space = images.line(" ", size: PillMetrics.bodySize, color: PillMetrics.primary).advance
        for (i, word) in s.words.enumerated() {
            let index = first + i
            guard index > lastWordIndex else { continue }
            let img = images.line(word, size: PillMetrics.bodySize, weight: .regular, color: PillMetrics.primary)
            let l = CALayer()
            l.contents = img.image
            l.contentsScale = scale
            l.anchorPoint = .zero
            l.bounds = CGRect(origin: .zero, size: img.size)
            l.opacity = 0
            wordsStrip.addSublayer(l)
            let x = wordsEnd + (index == 0 ? 0 : space)
            var a = Spring(0, params: SpringParams(response: 0.32, damping: 1))
            a.target = 1
            words[index] = Word(layer: l, x: x, width: img.size.width, alpha: a)
            wordsEnd = x + img.advance
            lastWordIndex = index
        }
        // Keep the newest word's end at the right edge of the words area.
        mo.scroll.target = max(0, wordsEnd - PillMetrics.wordsWidth)
        for (k, w) in words where w.x + w.width < mo.scroll.value - 40 {
            w.layer.removeFromSuperlayer()
            words[k] = nil
        }
    }

    private func clearWords() {
        words.values.forEach { $0.layer.removeFromSuperlayer() }
        words = [:]
        wordsEnd = 0
        lastWordIndex = -1
        mo.scroll.snap(to: 0)
    }

    // MARK: - Apply

    private func apply(state: PillState, time: Double) {
        let m = PillMetrics.self
        let w = CGFloat(mo.width.value), h = CGFloat(mo.height.value)
        let canvas = Self.canvasSize
        let centre = CGPoint(x: canvas.width / 2 + CGFloat(mo.shake.value), y: m.bottomInset + h / 2)

        pill.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        pill.position = centre
        let s = CGFloat(mo.scaleS.value)
        pill.transform = CATransform3DMakeScale(s, s, 1)
        pill.opacity = Float(max(0, min(1, mo.presence.value)))
        pillFrame = CGRect(x: centre.x - w / 2, y: centre.y - h / 2, width: w, height: h)

        // Corner radius: a capsule while pill-height, easing to the card radius as it grows.
        let radius = min(h / 2, m.cardRadius)
        body.frame = pill.bounds
        body.cornerRadius = radius
        shadow.frame = pill.bounds
        shadow.shadowPath = CGPath(roundedRect: pill.bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // How far the card has opened, 0...1. Pill content leaves early, card content arrives late.
        let open = max(0, min(1, (h - m.height) / max(1, cardSize.height - m.height)))
        let pillContent = Float(1 - smoothstep(0, 0.35, Double(open)))
        let cardContent = Float(smoothstep(0.68, 1, Double(open)) * mo.aCard.value)

        // Voice visual
        let vw = CGFloat(mo.visualW.value)
        visualHost.frame = snap(CGRect(x: m.padding, y: (m.height - m.visualHeight) / 2, width: vw, height: m.visualHeight))
        visualHost.opacity = Float(mo.aVisual.value) * pillContent
        if mo.aVisual.value > 0.001 {
            visual.update(history: history, size: visualHost.bounds.size, time: time, tint: tintColor())
        }

        // Hands-free: timer and stop button, anchored to the right edge.
        stopButton.frame = stopFrame(width: w)
        let stopX = stopButton.frame.minX
        let timeImg = timeImage(for: state.elapsed(at: time))
        let timeX = stopX - 8 - timeImg.size.width
        set(timeLabel, timeImg, at: CGPoint(x: timeX, y: (m.height - timeImg.size.height) / 2))
        // Content only shows once the pill has grown room for it, so nothing overlaps mid-morph.
        let visualRight = m.padding + vw
        timeLabel.opacity = Float(mo.aTime.value * room(timeX - visualRight - 8)) * pillContent
        stopButton.opacity = Float(mo.aTime.value * room(stopX - visualRight - 8)) * pillContent

        // Middle: no-signal message or live words.
        let midX = visualRight + m.gap
        let rightLimit = mo.aTime.target > 0 ? timeX - m.gap : w - m.padding
        let msg = messageImage
        set(message, msg, at: CGPoint(x: midX, y: (m.height - msg.size.height) / 2))
        message.opacity = Float(mo.aMessage.value * room(rightLimit - midX - msg.size.width)) * pillContent
        wordsClip.frame = snap(CGRect(x: midX, y: 0, width: m.wordsWidth, height: m.height))
        wordsFade.frame = wordsClip.bounds
        wordsClip.opacity = Float(mo.aWords.value * room(rightLimit - midX - m.wordsWidth)) * pillContent
        wordsStrip.frame = CGRect(x: -CGFloat(mo.scroll.value), y: 0, width: max(1, wordsEnd), height: m.height)
        for w in words.values {
            w.layer.position = CGPoint(x: w.x, y: ((m.height - w.layer.bounds.height) / 2).rounded())
            w.layer.opacity = Float(w.alpha.value)
        }

        applyNotice(state: state, width: w)
        applyCard(state: state, size: CGSize(width: w, height: h), alpha: cardContent)

        applyPressed(cardReason: state.cardReason)

        (clickZone, hits) = settledHits(state)
    }

    /// Button fills, with the held-down button lighter (darker for the white main button).
    private func applyPressed(cardReason: CardReason?) {
        let m = PillMetrics.self
        let bases: [(CALayer, CGColor, CGColor)] = [
            (stopButton, m.buttonFill, m.buttonPressed), (noticeButton, m.buttonFill, m.buttonPressed),
            (reasonButton, m.buttonFill, m.buttonPressed), (dismissButton, m.buttonFill, m.buttonPressed),
            cardReason == nil ? (copyButton, m.buttonFill, m.buttonPressed) : (copyButton, m.primaryButtonFill, m.primaryButtonPressed),
            (pasteButton, m.primaryButtonFill, m.primaryButtonPressed),
        ]
        for (l, base, pressed) in bases {
            let k = l === pressedLayer ? CGFloat(max(0, min(1, press.value))) : 0
            l.backgroundColor = k == 0 ? base : mix(base, pressed, k)
        }
    }

    private func mix(_ a: CGColor, _ b: CGColor, _ t: CGFloat) -> CGColor {
        let x = a.components ?? [0, 0, 0, 0], y = b.components ?? [0, 0, 0, 0]
        guard x.count == 4, y.count == 4 else { return t < 0.5 ? a : b }
        return CGColor(srgbRed: x[0] + (y[0] - x[0]) * t, green: x[1] + (y[1] - x[1]) * t,
                       blue: x[2] + (y[2] - x[2]) * t, alpha: x[3] + (y[3] - x[3]) * t)
    }

    private func applyNotice(state: PillState, width w: CGFloat) {
        let m = PillMetrics.self
        var icon: String?, text = "", button: String?
        var close = true
        switch state.phase {
        case .waitingForField: icon = nil; text = Self.waitingText; button = Self.waitingButton
        case .copied: icon = "checkmark"; text = "Copied"; close = false
        case .error(let e): (icon, text, button) = errorNotice(e)
        default:
            noticeIcon.opacity = Float(mo.aNotice.value); noticeText.opacity = Float(mo.aNotice.value)
            noticeButton.opacity = Float(mo.aNotice.value)
            return
        }
        var textX = m.padding
        if let icon {
            let iconImg = images.symbol(icon, size: 12, weight: .medium, color: m.secondary)
            set(noticeIcon, iconImg, at: CGPoint(x: m.padding, y: (m.height - iconImg.size.height) / 2))
            textX += iconImg.size.width + 8
        }
        noticeIcon.isHidden = icon == nil
        let textImg = images.line(text, size: m.bodySize, weight: .medium, color: m.primary)
        set(noticeText, textImg, at: CGPoint(x: textX, y: (m.height - textImg.size.height) / 2))
        if let button {
            let b = images.line(button, size: m.smallSize, weight: .medium, color: m.primary)
            noticeButton.frame = noticeButtonFrame(width: w, button: button)
            noticeButton.cornerRadius = m.buttonSize / 2
            set(noticeButtonText, b, at: CGPoint(x: 12, y: (m.buttonSize - b.size.height) / 2))
            noticeButtonText.opacity = 1; closeGlyph.opacity = 0
        } else if close {
            noticeButton.frame = noticeButtonFrame(width: w, button: nil)
            noticeButton.cornerRadius = m.buttonSize / 2
            let g = images.symbol("xmark", size: 9, weight: .bold, color: m.secondary)
            set(closeGlyph, g, at: CGPoint(x: (m.buttonSize - g.size.width) / 2, y: (m.buttonSize - g.size.height) / 2))
            noticeButtonText.opacity = 0; closeGlyph.opacity = 1
        } else {
            noticeButtonText.opacity = 0; closeGlyph.opacity = 0
        }
        let a = Float(mo.aNotice.value)
        noticeIcon.opacity = a; noticeText.opacity = a; noticeButton.opacity = close || button != nil ? a : 0
    }

    private func applyCard(state: PillState, size: CGSize, alpha: Float) {
        let m = PillMetrics.self
        let text: String
        switch state.phase {
        case .card(let t): text = t
        default:
            [cardText, reasonIcon, reasonText, reasonButton, copyButton, pasteButton, dismissButton].forEach { $0.opacity = alpha }
            return
        }
        let reason = state.cardReason
        let copied = state.cardCopied && reason == nil
        let para = images.paragraph(text, size: m.bodySize, width: m.cardWidth - 2 * m.cardPadding, maxLines: Self.cardLines, color: m.primary)
        set(cardText, para, at: CGPoint(x: m.cardPadding, y: size.height - 14 - para.size.height))

        // Buttons, right to left: the primary one, then Copy, then Dismiss.
        let buttons = cardButtons(width: size.width, reason: reason, copied: copied)
        for b in buttons {
            b.layer.frame = b.frame
            b.layer.cornerRadius = m.cardButtonHeight / 2
            set(b.label, b.image, at: CGPoint(x: 13, y: (m.cardButtonHeight - b.image.size.height) / 2))
        }

        // Above the actions: the reason and its fix, or "Copied".
        let blockY = reasonBlockY(reason)
        let blockH = noteBlockHeight(reason, copied: copied)
        if let reason {
            let icon = images.symbol(reason == .accessibilityOff ? "lock" : "doc.on.clipboard", size: 12, weight: .medium, color: m.secondary)
            let sentence = reasonParagraph(reason)
            set(reasonIcon, icon, at: CGPoint(x: m.cardPadding, y: blockY + (blockH - icon.size.height) / 2))
            set(reasonText, sentence, at: CGPoint(x: m.cardPadding + Self.reasonIndent, y: blockY + (blockH - sentence.size.height) / 2))
            let label = images.line(reason.actionTitle, size: m.smallSize, weight: .medium, color: m.primary)
            reasonButton.frame = reasonButtonFrame(width: size.width, reason: reason)
            reasonButton.cornerRadius = 12
            set(reasonButtonText, label, at: CGPoint(x: 11, y: (24 - label.size.height) / 2))
        } else {
            let icon = images.symbol(copied ? "checkmark" : "text.cursor", size: 11, weight: .semibold, color: m.secondary)
            let note = noteImage(copied: copied)
            set(reasonIcon, icon, at: CGPoint(x: m.cardPadding, y: blockY + (blockH - icon.size.height) / 2))
            set(reasonText, note, at: CGPoint(x: m.cardPadding + icon.size.width + 6, y: blockY + (blockH - note.size.height) / 2))
        }
        [reasonIcon, reasonText].forEach { $0.opacity = alpha }
        reasonButton.opacity = reason == nil ? 0 : alpha
        [cardText, dismissButton].forEach { $0.opacity = alpha }
        copyButton.opacity = buttons.contains { $0.hit == .copy } ? alpha : 0
        pasteButton.opacity = reason == nil ? alpha : 0
    }

    private func tintColor() -> CGColor {
        let a = theme.accent.color.components ?? [1, 1, 1, 1]
        let q = PillMetrics.quiet.components ?? [1, 1, 1, 0.3]
        let t = CGFloat(max(0, min(1, mo.tint.value)))
        return CGColor(srgbRed: q[0] + (a[0] - q[0]) * t, green: q[1] + (a[1] - q[1]) * t,
                       blue: q[2] + (a[2] - q[2]) * t, alpha: q[3] + (a[3] - q[3]) * t)
    }

    private func set(_ l: CALayer, _ r: TextImages.Rendered, at origin: CGPoint) {
        if l.contents as! CGImage? !== r.image { l.contents = r.image }
        l.frame = snap(CGRect(origin: origin, size: r.size))
    }

    /// Rounds to the pixel grid so text stays sharp.
    private func snap(_ r: CGRect) -> CGRect {
        CGRect(x: (r.minX * scale).rounded() / scale, y: (r.minY * scale).rounded() / scale, width: r.width, height: r.height)
    }

    /// 0 when `slack` points are missing, 1 once there are a few points to spare.
    private func room(_ slack: CGFloat) -> Double {
        smoothstep(-14, 2, Double(slack))
    }

    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: - Build

    private func build() {
        let m = PillMetrics.self
        layer.bounds = CGRect(origin: .zero, size: Self.canvasSize)
        layer.anchorPoint = .zero
        layer.position = .zero

        shadow.shadowColor = CGColor(gray: 0, alpha: 1)
        shadow.shadowOpacity = m.shadowOpacity
        shadow.shadowRadius = m.shadowRadius
        shadow.shadowOffset = CGSize(width: 0, height: m.shadowOffsetY)
        pill.addSublayer(shadow)

        body.backgroundColor = m.ink
        body.cornerCurve = .continuous
        body.masksToBounds = true
        body.borderWidth = 0.5
        body.borderColor = m.hairline
        pill.addSublayer(body)

        body.addSublayer(visualHost)
        visualHost.addSublayer(visual.layer)

        stopButton.backgroundColor = m.buttonFill
        stopButton.cornerRadius = m.buttonSize / 2
        applyStopGlyph()
        stopButton.addSublayer(stopGlyph)

        wordsClip.masksToBounds = true
        wordsFade.startPoint = CGPoint(x: 0, y: 0.5)
        wordsFade.endPoint = CGPoint(x: 1, y: 0.5)
        wordsFade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)]
        wordsFade.locations = [0, 0.16, 0.96, 1]
        wordsClip.mask = wordsFade
        wordsStrip.anchorPoint = .zero
        wordsClip.addSublayer(wordsStrip)

        noticeButton.backgroundColor = m.buttonFill
        noticeButton.addSublayer(noticeButtonText)
        noticeButton.addSublayer(closeGlyph)

        pasteButton.backgroundColor = m.primaryButtonFill
        pasteButton.addSublayer(pasteText)
        copyButton.backgroundColor = m.buttonFill
        copyButton.addSublayer(copyText)
        reasonButton.backgroundColor = m.buttonFill
        reasonButton.addSublayer(reasonButtonText)
        dismissButton.backgroundColor = m.buttonFill
        dismissButton.addSublayer(dismissText)

        for l in [timeLabel, stopButton, message, wordsClip, noticeIcon, noticeText, noticeButton,
                  cardText, reasonIcon, reasonText, reasonButton, copyButton, pasteButton, dismissButton] {
            l.opacity = 0
            body.addSublayer(l)
        }
        layer.addSublayer(pill)
        pill.opacity = 0
        setScale(on: layer)
    }

    private func applyStopGlyph() {
        let m = PillMetrics.self
        let stop = images.symbol("stop.fill", size: 9, weight: .bold, color: m.primary)
        stopGlyph.contents = stop.image
        stopGlyph.frame = CGRect(x: ((m.buttonSize - stop.size.width) / 2).rounded(), y: ((m.buttonSize - stop.size.height) / 2).rounded(),
                                 width: stop.size.width, height: stop.size.height)
    }

    /// Switches to another display's pixel density (the pill moved to a 1x or 2x screen). Text
    /// bitmaps are drawn at the new density and layers are told their contents scale. Call while the
    /// pill is hidden; the next show starts clean.
    public func setBackingScale(_ new: CGFloat) {
        guard new > 0, new != scale else { return }
        scale = new
        images = TextImages(scale: new)
        clearWords()
        prewarm()
        applyStopGlyph()
        setScale(on: layer)
    }

    private func rebuildVisual() {
        visual.layer.removeFromSuperlayer()
        visual = makeVoiceVisual(theme.visual)
        visualHost.addSublayer(visual.layer)
        setScale(on: visual.layer)
    }

    private func setScale(on root: CALayer) {
        root.contentsScale = scale
        root.sublayers?.forEach { setScale(on: $0) }
        if let mask = root.mask { setScale(on: mask) }
    }
}
