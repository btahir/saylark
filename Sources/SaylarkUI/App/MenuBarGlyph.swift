import AppKit
import SaylarkCore

/// The menu bar icon: a tiny pill with a voice trace inside, drawn as a template image so it follows
/// the menu bar's appearance. The state changes the capsule; no colour is used.
@MainActor public enum MenuBarGlyph {
    public enum State: String, CaseIterable, Sendable {
        /// Ready.
        case idle
        /// A take is running: filled capsule, trace knocked out.
        case listening
        /// Paused for an hour: faded, with a slash.
        case paused
        /// Something needs attention (permission, model, start failure): a dot on the corner.
        case problem
    }

    public static let size = NSSize(width: 20, height: 18)

    private static var cache: [State: NSImage] = [:]

    /// One shared image per state: the menu bar button gets the same object each time, and the
    /// drawing runs once.
    public static func image(_ state: State) -> NSImage {
        if let hit = cache[state] { return hit }
        let made = render(state)
        cache[state] = made
        return made
    }

    private static func render(_ state: State) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(state, in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Saylark, \(description(state))"
        return image
    }

    private static func description(_ state: State) -> String {
        switch state {
        case .idle: "ready"
        case .listening: "listening"
        case .paused: "paused"
        case .problem: "needs attention"
        }
    }

    /// Bar heights of the little trace, in points, left to right.
    private static let bars: [CGFloat] = [2.4, 5.0, 3.4, 1.8]

    private static func draw(_ state: State, in rect: NSRect) {
        let capsule = NSRect(x: 1.75, y: 4.75, width: 16.5, height: 8.5)
        let path = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
        let alpha: CGFloat = state == .paused ? 0.5 : 1
        NSColor.black.withAlphaComponent(alpha).set()

        let barWidth: CGFloat = 1.4, gap: CGFloat = 1.4
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
        var x = capsule.midX - total / 2
        let traces = bars.map { h -> NSBezierPath in
            let r = NSRect(x: x, y: capsule.midY - h / 2, width: barWidth, height: h)
            x += barWidth + gap
            return NSBezierPath(roundedRect: r, xRadius: barWidth / 2, yRadius: barWidth / 2)
        }

        if state == .listening {
            path.fill()
            NSGraphicsContext.current?.compositingOperation = .clear
            traces.forEach { $0.fill() }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            path.lineWidth = 1.3
            path.stroke()
            traces.forEach { $0.fill() }
        }
        if state == .paused {
            NSColor.black.set()
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 4.5, y: 3))
            slash.line(to: NSPoint(x: 15.5, y: 15))
            slash.lineWidth = 1.4
            slash.lineCapStyle = .round
            slash.stroke()
        }
        if state == .problem {
            // A dot on the top right corner, with a gap cut around it so it reads at 18 pt.
            let dot = NSRect(x: 14.6, y: 11.6, width: 4.2, height: 4.2)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.4, dy: -1.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.set()
            NSBezierPath(ovalIn: dot).fill()
        }
    }
}
