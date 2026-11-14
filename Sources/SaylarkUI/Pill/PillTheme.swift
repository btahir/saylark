import CoreGraphics

/// The one signal colour used for "listening". Everything else on the pill is monochrome.
public enum PillAccent: String, CaseIterable, Sendable {
    case ember, mint, amber, white

    public var color: CGColor {
        switch self {
        case .ember: CGColor(srgbRed: 1.0, green: 0.42, blue: 0.24, alpha: 1)    // #FF6B3D
        case .mint: CGColor(srgbRed: 0.27, green: 0.88, blue: 0.66, alpha: 1)    // #45E0A8
        case .amber: CGColor(srgbRed: 1.0, green: 0.77, blue: 0.29, alpha: 1)    // #FFC44A
        case .white: CGColor(srgbRed: 0.96, green: 0.96, blue: 0.96, alpha: 1)
        }
    }
}

/// Which voice visual the pill draws. See notes/design/critique.md for why each exists.
/// Declared default first: Settings lists them in this order.
public enum VoiceVisualKind: String, CaseIterable, Sendable {
    /// Five dots that stretch with the voice, rippling out from the centre. The default.
    case seeds
    /// Scrolling, mirrored envelope of the last ~1.4 s.
    case trace
    /// A thin carrier wave whose height is the envelope, scrolling like the trace.
    case wave
}

/// Everything that decides how the pill looks. Value type, so the lab can swap options live.
public struct PillTheme: Sendable, Equatable {
    public var accent: PillAccent = .ember
    /// Seeds by default (owner's pick, 2026-11-10); live words off, so the pill stays small.
    public var visual: VoiceVisualKind = .seeds
    public var liveWords = false
    public var reduceMotion = false

    public init(accent: PillAccent = .ember, visual: VoiceVisualKind = .seeds, liveWords: Bool = false, reduceMotion: Bool = false) {
        self.accent = accent
        self.visual = visual
        self.liveWords = liveWords
        self.reduceMotion = reduceMotion
    }
}

/// Colours and sizes, in points. One place, so the notes and the code can't drift.
enum PillMetrics {
    // Colours
    static let ink = CGColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1)
    static let hairline = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.11)
    static let primary = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.94)
    static let secondary = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.56)
    static let quiet = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30)
    static let buttonFill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12)
    static let primaryButtonFill = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.94)
    /// Held down: the plain buttons light up, the white main button dims.
    static let buttonPressed = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.34)
    static let primaryButtonPressed = CGColor(srgbRed: 0.66, green: 0.66, blue: 0.68, alpha: 1)

    // Pill
    static let height: CGFloat = 32
    static let holdWidth: CGFloat = 112
    static let padding: CGFloat = 14
    /// Inset of round buttons inside the capsule. Button radius + inset = capsule radius (concentric).
    static let buttonInset: CGFloat = 4
    static var buttonSize: CGFloat { height - 2 * buttonInset }
    static let gap: CGFloat = 10
    static let visualHeight: CGFloat = 18
    static let visualWidthHold: CGFloat = 76
    static let visualWidthCompact: CGFloat = 44
    static let wordsWidth: CGFloat = 196
    static let bottomInset: CGFloat = 18

    // Card
    static let cardWidth: CGFloat = 360
    static let cardPadding: CGFloat = 16
    static let cardButtonHeight: CGFloat = 28
    static let cardButtonInset: CGFloat = 8
    static var cardRadius: CGFloat { cardButtonHeight / 2 + cardButtonInset }

    // Type
    static let bodySize: CGFloat = 13
    static let smallSize: CGFloat = 12

    // Shadow
    static let shadowOpacity: Float = 0.28
    static let shadowRadius: CGFloat = 10
    static let shadowOffsetY: CGFloat = -4
}

/// Spring settings. Notes in notes/M0-pill.md.
enum PillSprings {
    /// Appear: scale 0.6 → 1, slight overshoot, 95% there in about 140 ms.
    static let appear = SpringParams(response: 0.24, damping: 0.74)
    static let fadeIn = SpringParams(response: 0.12, damping: 1)
    /// Exit: no bounce, gone in about 120 ms.
    static let exit = SpringParams(response: 0.13, damping: 1)
    /// Opacity leads the shrink slightly, so the ink spends less time as a grey half-fade.
    static let exitFade = SpringParams(response: 0.11, damping: 1)
    /// Width/height changes between pill states.
    static let morph = SpringParams(response: 0.34, damping: 0.84)
    /// Card expand.
    static let card = SpringParams(response: 0.38, damping: 0.82)
    /// Content cross-fades.
    static let content = SpringParams(response: 0.2, damping: 1)
    /// Esc shake: lightly damped, kicked with an initial velocity.
    static let shake = SpringParams(response: 0.1, damping: 0.22)
    /// Initial shake velocity in pt/s. 510 gives a first swing of about 6 pt (owner, 2026-10-21).
    static let shakeKick: Double = 510
    /// Live words scrolling and accent drain.
    static let scroll = SpringParams(response: 0.24, damping: 1)
    /// Accent drains gently when the signal goes, and comes back promptly with the voice.
    static let tint = SpringParams(response: 0.5, damping: 1)
    static let tintReturn = SpringParams(response: 0.22, damping: 1)

    /// Reduce Motion: no scale, no overshoot, no shake. Changes are quick dissolves.
    static let reduced = SpringParams(response: 0.14, damping: 1)
}
