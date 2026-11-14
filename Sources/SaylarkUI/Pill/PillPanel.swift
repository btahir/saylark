import AppKit
import QuartzCore
import SaylarkCore

/// The floating pill: a borderless, non-activating panel created once at launch and kept hidden.
/// It never becomes key or main, so the app you are typing into keeps focus. A display link runs only
/// while the pill is on screen; at rest there are no timers.
///
/// Clicks: the drawing panel never takes them (it is bigger than the pill, for the shadow and the
/// morphs). A second, invisible panel sits exactly over the settled pill while it has buttons and
/// takes every click there; everywhere else clicks reach the app behind. It used to be one panel
/// whose `ignoresMouseEvents` was switched once per frame from the pointer position. The switch
/// always came after the mouse moved onto a button, so the window server had already routed that
/// pointer position to the app behind, and the first click there could go to that app: the
/// button only worked on the second click.
@MainActor public final class PillPanel {
    public let view: PillView
    public let panel: NSPanel
    /// Takes the pill's clicks. On screen only while the pill has something to click.
    public let clickPanel: NSPanel
    private let host: PillHostView
    private let catcher: PillClickView
    private var link: CADisplayLink?
    private let target = DisplayLinkTarget()
    private var lastTimestamp: CFTimeInterval = 0
    private var hovering = false
    /// The click panel's frame on screen, or nil while it is off screen.
    public private(set) var clickFrame: CGRect?
    /// The pill's click area in its root coordinates, matching `clickFrame`.
    private var clickZone: CGRect?
    /// False in tests: nothing is ordered on screen.
    var ordersWindows = true

    /// Called every frame for the current state, the time on the same clock as the state, and the
    /// mic RMS (nil when not listening).
    public var frameSource: (() -> (state: PillState, time: Double, rms: Float?))?
    public var onHit: ((PillHit) -> Void)?
    public var onHover: ((Bool) -> Void)?

    /// Recent per-frame cost of `PillView.update` plus the commit, in milliseconds.
    public private(set) var recentCosts: [Double] = []

    public init(theme: PillTheme = PillTheme()) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        view = PillView(theme: theme, scale: scale)
        panel = PillNSPanel(contentRect: CGRect(origin: .zero, size: PillView.canvasSize),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        Self.configure(panel)
        panel.ignoresMouseEvents = true
        host = PillHostView(frame: CGRect(origin: .zero, size: PillView.canvasSize))
        host.layer?.addSublayer(view.layer)
        panel.contentView = host

        clickPanel = PillNSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        Self.configure(clickPanel)
        // Set on purpose (not left at the default), so the whole panel takes clicks, and an
        // all-but-invisible fill so no pixel of it counts as transparent to the window server.
        clickPanel.ignoresMouseEvents = false
        clickPanel.backgroundColor = NSColor(white: 0, alpha: 1.0 / 255)
        catcher = PillClickView(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        clickPanel.contentView = catcher
        catcher.onDown = { [weak self] p in self?.mouseDown(at: p) }
        catcher.onUp = { [weak self] in self?.view.setPressed(nil); self?.wake() }
        target.onFrame = { [weak self] link in self?.frame(link) }
    }

    private static func configure(_ p: NSPanel) {
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isMovable = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
    }

    /// Places the panel at the bottom centre of `screen`'s visible area (above the Dock).
    public func place(on screen: NSScreen) {
        // Text bitmaps are drawn for the density of the screen the pill is on, so a 1x external next
        // to a 2x built-in display is as sharp as either. Only while hidden, so a live pill never
        // loses its words.
        if !panel.isVisible { view.setBackingScale(screen.backingScaleFactor) }
        let v = screen.visibleFrame
        panel.setFrameOrigin(CGPoint(x: (v.midX - PillView.canvasSize.width / 2).rounded(), y: v.minY))
        syncClickPanel()
    }

    /// Starts drawing. Call on the first event of a take; the pill is visible on the next frame.
    public func wake() {
        if ordersWindows, !panel.isVisible { panel.orderFrontRegardless() }
        guard link == nil, ordersWindows else { return }
        let l = host.displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
    }

    /// A press on the click panel, `p` in its own coordinates. The button shows pressed and its
    /// action runs at once; a press between buttons does nothing (and does not reach the app behind).
    func mouseDown(at p: CGPoint) {
        guard let zone = clickZone, let hit = view.hit(CGPoint(x: p.x + zone.minX, y: p.y + zone.minY)) else { return }
        view.setPressed(hit)
        onHit?(hit)
        wake()
    }

    private func frame(_ link: CADisplayLink) {
        guard let (state, time, rms) = frameSource?() else { return }
        let dt = lastTimestamp == 0 ? link.duration : link.targetTimestamp - lastTimestamp
        lastTimestamp = link.targetTimestamp
        let start = DispatchTime.now().uptimeNanoseconds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.update(state: state, time: time, rms: rms, dt: min(max(dt, 1.0 / 240), 1.0 / 30))
        CATransaction.commit()
        recentCosts.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        if recentCosts.count > 600 { recentCosts.removeFirst(recentCosts.count - 600) }

        syncClickPanel()

        // Hover keeps the card and notices open. Polled once per frame while visible; no monitors.
        let mouse = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inside = view.pillFrame.contains(mouse) || (clickZone?.contains(mouse) ?? false)
        if inside != hovering {
            hovering = inside
            onHover?(inside)
        }

        if view.isIdle {
            link.invalidate()
            self.link = nil
            panel.orderOut(nil)
            syncClickPanel()
        }
    }

    /// Puts the click panel over the settled pill while it has buttons, and takes it away when
    /// it has none. Changes the window only when the area changes.
    func syncClickPanel() {
        let zone = view.isIdle ? nil : view.clickZone?.integral
        let origin = panel.frame.origin
        let frame = zone?.offsetBy(dx: origin.x, dy: origin.y)
        clickZone = zone
        guard frame != clickFrame else { return }
        clickFrame = frame
        if let frame {
            clickPanel.setFrame(frame, display: false)
            if ordersWindows, !clickPanel.isVisible { clickPanel.orderFrontRegardless() }
        } else {
            view.setPressed(nil)
            if clickPanel.isVisible { clickPanel.orderOut(nil) }
        }
    }
}

/// Never key, never main: the target app keeps focus and keystrokes.
private final class PillNSPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Layer-hosting view for the pill. Draws only; its panel never takes clicks.
final class PillHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let root = CALayer()
        root.masksToBounds = false
        layer = root
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }
}

/// The click panel's content: reports presses in its own coordinates. The first click counts
/// (the app stays inactive and the panel never becomes key).
final class PillClickView: NSView {
    var onDown: ((CGPoint) -> Void)?
    var onUp: (() -> Void)?

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        onDown?(convert(event.locationInWindow, from: nil))
    }
    override func mouseUp(with event: NSEvent) { onUp?() }
}

/// Selector target for `NSView.displayLink`.
@MainActor final class DisplayLinkTarget: NSObject {
    var onFrame: ((CADisplayLink) -> Void)?
    @objc func tick(_ link: CADisplayLink) { onFrame?(link) }
}
