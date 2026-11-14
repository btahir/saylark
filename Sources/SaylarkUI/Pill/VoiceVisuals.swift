import QuartzCore

/// The display level over the last couple of seconds, one sample per frame. The voice visuals read
/// it at any age with interpolation, so motion stays smooth whatever the frame rate.
struct LevelHistory {
    private var buffer: [Double]
    private var head = 0
    let rate: Double

    init(rate: Double = 120, seconds: Double = 2.5) {
        self.rate = rate
        buffer = Array(repeating: 0, count: Int(rate * seconds))
    }

    /// Seconds of audio pushed so far. Stops while the history is frozen.
    private(set) var clock: Double = 0

    mutating func push(_ level: Double) {
        clock += 1 / rate
        head = (head + 1) % buffer.count
        buffer[head] = level
    }

    mutating func reset() {
        for i in buffer.indices { buffer[i] = 0 }
    }

    /// Level `age` seconds ago (0 = newest).
    func level(ago age: Double) -> Double {
        let x = max(0, age * rate)
        let i = Int(x)
        guard i + 1 < buffer.count else { return 0 }
        let f = x - Double(i)
        let a = buffer[(head - i + buffer.count) % buffer.count]
        let b = buffer[(head - i - 1 + buffer.count) % buffer.count]
        return a + (b - a) * f
    }

    var current: Double { buffer[head] }
}

/// A voice visual: a layer that redraws itself from the level history each frame.
@MainActor protocol VoiceVisual: AnyObject {
    var layer: CALayer { get }
    /// `size` is the box in points; `time` drives any idle motion; `tint` is the current colour.
    func update(history: LevelHistory, size: CGSize, time: Double, tint: CGColor)
}

@MainActor func makeVoiceVisual(_ kind: VoiceVisualKind) -> any VoiceVisual {
    switch kind {
    case .trace: TraceVisual()
    case .wave: WaveVisual()
    case .seeds: SeedsVisual()
    }
}

/// Mirrored envelope of the last ~1.4 s scrolling right to left, newest at the right edge. It is a
/// literal picture of what the mic heard: syllables are bumps, pauses are flat. Older audio fades out.
@MainActor final class TraceVisual: VoiceVisual {
    let layer = CALayer()
    private let shape = CAShapeLayer()
    private let fade = CAGradientLayer()
    /// Points per second of scroll.
    private let speed: Double = 52

    init() {
        layer.addSublayer(shape)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1)]
        fade.locations = [0, 0.42, 0.97, 1]
        shape.mask = fade
    }

    func update(history: LevelHistory, size: CGSize, time: Double, tint: CGColor) {
        let bounds = CGRect(origin: .zero, size: size)
        shape.frame = bounds
        fade.frame = bounds
        shape.fillColor = tint
        let mid = size.height / 2
        let step: CGFloat = 1.5
        let count = Int(size.width / step) + 1
        var tops: [CGPoint] = []
        tops.reserveCapacity(count + 1)
        let cap: CGFloat = 3
        for i in 0...count {
            let x = min(size.width, CGFloat(i) * step)
            let age = Double(size.width - x) / speed
            let level = history.level(ago: age)
            // Softer than linear so syllables stand out from the body of speech.
            var half = 0.75 + CGFloat(pow(level, 1.8)) * (mid * 0.9 - 0.75)
            // Round the newest edge like a cap instead of cutting it square.
            let fromEnd = size.width - x
            if fromEnd < cap { half = 0.75 + (half - 0.75) * sqrt(max(0, 1 - pow((cap - fromEnd) / cap, 2))) }
            tops.append(CGPoint(x: x, y: half))
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: mid + tops[0].y))
        smooth(path, tops.map { CGPoint(x: $0.x, y: mid + $0.y) })
        path.addLine(to: CGPoint(x: size.width, y: mid - tops[tops.count - 1].y))
        smooth(path, tops.reversed().map { CGPoint(x: $0.x, y: mid - $0.y) })
        path.closeSubpath()
        shape.path = path
    }

    /// Quadratic curves through midpoints: smooth, never overshoots the samples.
    private func smooth(_ path: CGMutablePath, _ pts: [CGPoint]) {
        guard pts.count > 2 else { pts.forEach { path.addLine(to: $0) }; return }
        for i in 1..<(pts.count - 1) {
            let m = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.addQuadCurve(to: m, control: pts[i])
        }
        path.addLine(to: pts[pts.count - 1])
    }
}

/// A thin line drawn as a slow carrier wave whose height is the real envelope, scrolling with it like
/// the trace. It looks like a waveform passing by; every bump is a moment of your voice.
@MainActor final class WaveVisual: VoiceVisual {
    let layer = CALayer()
    private let shape = CAShapeLayer()
    private let fade = CAGradientLayer()
    private let speed: Double = 52
    /// Carrier wavelength in points.
    private let wavelength: Double = 13

    init() {
        shape.fillColor = nil
        shape.lineWidth = 1.6
        shape.lineCap = .round
        shape.lineJoin = .round
        layer.addSublayer(shape)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1)]
        fade.locations = [0, 0.4]
        shape.mask = fade
    }

    func update(history: LevelHistory, size: CGSize, time: Double, tint: CGColor) {
        let bounds = CGRect(origin: .zero, size: size)
        shape.frame = bounds
        fade.frame = bounds
        shape.strokeColor = tint
        let mid = size.height / 2
        let path = CGMutablePath()
        let n = Int(size.width * 2)
        // Phase is tied to audio time, so the wave travels left with its envelope.
        let head = history.clock * speed
        for i in 0...n {
            let x = Double(i) / 2
            let age = (Double(size.width) - x) / speed
            let amp = Double(mid - 1) * pow(history.level(ago: age), 1.2)
            let y = amp * sin(2 * .pi * (head - (Double(size.width) - x)) / wavelength)
            let p = CGPoint(x: x, y: Double(mid) + y)
            i == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        shape.path = path
    }
}

/// Five dots that stretch into capsules with the voice. The centre dot is the newest level and the
/// outer dots show it a moment later, so each syllable ripples outward. At rest they are dots.
@MainActor final class SeedsVisual: VoiceVisual {
    let layer = CALayer()
    private let dots: [CALayer]
    private let dot: CGFloat = 5
    private let spacing: CGFloat = 10

    init() {
        dots = (0..<5).map { _ in
            let l = CALayer()
            l.cornerCurve = .circular
            return l
        }
        dots.forEach(layer.addSublayer)
    }

    func update(history: LevelHistory, size: CGSize, time: Double, tint: CGColor) {
        let mid = size.height / 2
        let total = spacing * CGFloat(dots.count - 1)
        let x0 = size.width / 2 - total / 2
        for (i, l) in dots.enumerated() {
            let ring = abs(i - dots.count / 2)
            let level = history.level(ago: Double(ring) * 0.07)
            let gain = 1 - Double(ring) * 0.18
            let h = dot + CGFloat(pow(level, 0.85) * gain) * (size.height - dot)
            l.bounds = CGRect(x: 0, y: 0, width: dot, height: h)
            l.position = CGPoint(x: x0 + CGFloat(i) * spacing, y: mid)
            l.cornerRadius = dot / 2
            l.backgroundColor = tint
        }
    }
}
