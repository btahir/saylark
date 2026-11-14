import AppKit
import QuartzCore
import SaylarkCore
import SwiftUI

/// A live, looping pill for Settings: the real `PillView` driven by a recorded or synthetic voice,
/// so each voice visual can be judged in motion. It animates only while its window is on screen.
struct PillPreview: NSViewRepresentable {
    var theme: PillTheme
    /// Seconds of the loop to show before the first frame (renders use a mid-speech moment).
    var primeSeconds: Double = 1.6

    func makeNSView(context: Context) -> PillPreviewView {
        PillPreviewView(theme: theme, primeSeconds: primeSeconds)
    }

    func updateNSView(_ view: PillPreviewView, context: Context) {
        view.setTheme(theme)
    }
}

final class PillPreviewView: NSView {
    private var pill: PillView
    private var machine = PillMachine()
    private let voice: [Float]
    private let words: [TranscriptWord]
    private var time = 0.0
    private var link: CADisplayLink?
    private let target = DisplayLinkTarget()
    /// Words due in the current loop, and every word shown so far (the pill keeps the newest).
    private var shown = 0
    private var spoken: [String] = []
    /// Voice loop length, plus a short breath before it starts again.
    private var loop: Double { Double(voice.count) / 120 + 0.8 }

    init(theme: PillTheme, primeSeconds: Double) {
        pill = PillView(theme: theme, scale: 2)
        let sample = SampleTakes.records()[2]
        // Synthetic voice at speaking level (linear RMS), with a little room tone.
        voice = SampleTakes.envelope(for: sample).map { 0.0008 + $0 * 0.05 }
        words = sample.words
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.addSublayer(pill.layer)
        machine.handle(.listen, at: 0)
        let steps = Int(primeSeconds * 120)
        for _ in 0..<steps { step(1.0 / 120) }
        target.onFrame = { [weak self] l in self?.step(min(1.0 / 30, l.duration)) }
    }

    required init?(coder: NSCoder) { nil }

    func setTheme(_ theme: PillTheme) {
        guard theme != pill.theme else { return }
        pill.theme = theme
    }

    override func layout() {
        super.layout()
        // Centre the pill (which sits at the bottom of its canvas) in this view.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = PillView.canvasSize
        pill.layer.position = CGPoint(x: (bounds.width - c.width) / 2, y: bounds.midY - PillMetrics.bottomInset - PillMetrics.height / 2)
        CATransaction.commit()
    }

    private var windowObservers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        if let window {
            // The Settings and first-run windows are hidden, not released, when closed. Their previews
            // must stop with them: a display link keeps stepping the pill for a window nobody sees.
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification] {
                windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateLink(closing: name == NSWindow.willCloseNotification) }
                })
            }
        }
        updateLink()
    }

    /// True while the window can be seen: on screen, not occluded, not minimised.
    var shouldAnimate: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    var isAnimating: Bool { link != nil }

    private func updateLink(closing: Bool = false) {
        guard shouldAnimate, !closing else {
            link?.invalidate()
            link = nil
            return
        }
        guard link == nil else { return }
        let l = displayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func step(_ dt: Double) {
        time += dt
        let local = time.truncatingRemainder(dividingBy: loop)
        if local < dt { shown = 0 }
        let i = Int(local * 120)
        let rms: Float = i < voice.count ? voice[i] : 0.0008
        let due = words.prefix { $0.end + 0.3 <= local }.count
        if due > shown {
            spoken += words[shown..<due].map(\.text)
            shown = due
            machine.handle(.words(spoken), at: time)
        }
        machine.tick(at: time, peakDB: (rms * 2).dBFS)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pill.update(state: machine.state, time: time, rms: rms, dt: dt)
        CATransaction.commit()
    }
}
