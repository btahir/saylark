import AppKit
import Metal
import QuartzCore
import SaylarkCore

/// Renders a pill scenario frame by frame without a window or screen-recording permission.
///
/// The scene is an ordinary layer tree (backdrop + one or more `PillView`s) drawn by `CARenderer`
/// into a Metal texture, so masks, shadows and continuous corners match what Core Animation draws on
/// screen. Time is stepped exactly 1/fps per frame, never from the wall clock.
@MainActor public final class OffscreenRenderer {
    public let pointSize: CGSize
    public let scale: CGFloat
    public let fps: Double
    public var pixelWidth: Int { Int(pointSize.width * scale) }
    public var pixelHeight: Int { Int(pointSize.height * scale) }

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let texture: any MTLTexture
    private let renderer: CARenderer
    private let root = CALayer()
    private let content = CALayer()
    private let backdropLayer = CALayer()
    private var pills: [PillView] = []
    private var driver: PillDriver
    private let scenario: PillScenario
    private var frameIndex = 0
    private var nextPress = 0

    /// Per-frame cost of the pill work (state step + spring step + layer updates + commit), in ms of
    /// this thread's CPU time, so a preemption by another process doesn't count as pill work.
    public private(set) var frameCosts: [Double] = []
    /// The same, in wall-clock ms (includes preemption by other processes).
    public private(set) var wallCosts: [Double] = []

    public init?(scenario: PillScenario, pointSize: CGSize = CGSize(width: 800, height: 500), scale: CGFloat = 2, fps: Double = 120) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.scenario = scenario
        self.pointSize = pointSize
        self.scale = scale
        self.fps = fps
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: Int(pointSize.width * scale),
                                                            height: Int(pointSize.height * scale), mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        self.texture = texture
        renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: queue,
                                                              kCARendererColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        driver = PillDriver(events: scenario.events, voice: scenario.voice)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.bounds = CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        root.anchorPoint = .zero
        root.position = .zero
        root.backgroundColor = CGColor(gray: 0, alpha: 1)
        content.bounds = CGRect(origin: .zero, size: pointSize)
        content.anchorPoint = .zero
        content.position = .zero
        content.transform = CATransform3DMakeScale(scale, scale, 1)
        root.addSublayer(content)

        backdropLayer.frame = content.bounds
        backdropLayer.contents = scenario.backdrop.image(size: pointSize, scale: scale)
        content.addSublayer(backdropLayer)

        // Lanes: one pill at the bottom centre, or several stacked with labels.
        let lanes = scenario.lanes
        let canvas = PillView.canvasSize
        for (i, lane) in lanes.enumerated() {
            let pill = PillView(theme: lane.theme, scale: scale)
            if let name = lane.micName { pill.config.micName = name }
            let bottom: CGFloat
            if lanes.count == 1 {
                bottom = 0
            } else {
                let spacing = min(110, (pointSize.height - 60) / CGFloat(lanes.count))
                bottom = pointSize.height - 40 - spacing * CGFloat(i + 1) + 10
            }
            pill.layer.position = CGPoint(x: (pointSize.width - canvas.width) / 2, y: bottom)
            content.addSublayer(pill.layer)
            pills.append(pill)
            if let label = lane.label {
                addLabel(label, at: CGPoint(x: pointSize.width / 2 - 136, y: bottom + PillMetrics.bottomInset + 8), dark: scenario.backdrop.isDark)
            }
        }
        CATransaction.commit()
        renderer.layer = root
        renderer.bounds = root.bounds
        CATransaction.flush()
    }

    private func addLabel(_ text: String, at p: CGPoint, dark: Bool) {
        let images = TextImages(scale: scale)
        let color = dark ? CGColor(gray: 1, alpha: 0.8) : CGColor(gray: 0, alpha: 0.72)
        let img = images.line(text, size: 13, weight: .semibold, color: color)
        // A soft plate so the label reads on the busy wallpaper.
        let plate = CALayer()
        plate.backgroundColor = dark ? CGColor(gray: 0, alpha: 0.45) : CGColor(gray: 1, alpha: 0.7)
        plate.frame = CGRect(x: p.x - 8, y: p.y - 4, width: img.size.width + 16, height: img.size.height + 8)
        plate.cornerRadius = 6
        plate.contentsScale = scale
        let l = CALayer()
        l.contents = img.image
        l.contentsScale = scale
        l.frame = CGRect(x: 8, y: 4, width: img.size.width, height: img.size.height)
        plate.addSublayer(l)
        content.addSublayer(plate)
    }

    public var frameCount: Int { Int((scenario.duration * fps).rounded()) }

    public var time: Double { Double(frameIndex) / fps }

    /// Advances one frame and renders it. Returns BGRA pixels, top row first.
    public func renderNextFrame() -> Data {
        let t = Double(frameIndex) / fps
        let dt = 1 / fps

        let start = DispatchTime.now().uptimeNanoseconds
        let cpu0 = threadCPUNanoseconds()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        driver.advance(to: t)
        // Mouse down / up on a button, as the panel shows it (the action is a scripted event).
        while nextPress < scenario.presses.count, scenario.presses[nextPress].time <= t {
            for p in pills { p.setPressed(scenario.presses[nextPress].hit) }
            nextPress += 1
        }
        let rms = driver.rms(at: t)
        for p in pills { p.update(state: driver.state, time: t, rms: rms, dt: dt) }
        CATransaction.commit()
        CATransaction.flush()
        frameCosts.append(Double(threadCPUNanoseconds() - cpu0) / 1e6)
        wallCosts.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)

        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        if let cb = queue.makeCommandBuffer() {
            cb.commit()
            cb.waitUntilCompleted()
        }
        frameIndex += 1
        return readPixels()
    }

    public var state: PillState { driver.state }

    /// Pill frames in pixel coordinates (top-left origin), for cropping stills.
    public var pillRectsInPixels: [CGRect] {
        pills.map { p in
            let f = p.pillFrame.offsetBy(dx: p.layer.position.x, dy: p.layer.position.y)
            return CGRect(x: f.minX * scale, y: (pointSize.height - f.maxY) * scale, width: f.width * scale, height: f.height * scale)
        }
    }

    /// The canvas of the first pill in pixels (top-left origin): a stable crop for contact sheets.
    public var stageRectInPixels: CGRect {
        let c = PillView.canvasSize
        let origins = pills.map(\.layer.position)
        let minY = origins.map(\.y).min() ?? 0, maxY = (origins.map(\.y).max() ?? 0) + c.height
        let x = origins.first?.x ?? 0
        return CGRect(x: x * scale, y: (pointSize.height - maxY) * scale, width: c.width * scale, height: (maxY - minY) * scale)
    }

    private func readPixels() -> Data {
        let w = pixelWidth, h = pixelHeight, row = w * 4
        var data = Data(count: row * h)
        data.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: row, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            // CARenderer fills the texture bottom row first; flip to top row first.
            let p = buf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            var tmp = [UInt8](repeating: 0, count: row)
            for y in 0..<(h / 2) {
                let a = p + y * row, b = p + (h - 1 - y) * row
                tmp.withUnsafeMutableBytes { t in
                    t.baseAddress!.copyMemory(from: a, byteCount: row)
                    a.update(from: b, count: row)
                    b.update(from: t.baseAddress!.assumingMemoryBound(to: UInt8.self), count: row)
                }
            }
        }
        return data
    }

    /// Wraps BGRA pixels in a CGImage.
    public func image(from pixels: Data) -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixelWidth * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// CPU time used by the calling thread, in nanoseconds.
func threadCPUNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
}
