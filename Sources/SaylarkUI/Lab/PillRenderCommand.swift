import AppKit
import ImageIO
import SaylarkCore
import UniformTypeIdentifiers

public struct PillRenderOptions: Sendable {
    public var stillsOnly = false
    public var slowMotion = true
    /// Overrides for single-lane scenarios.
    public var accent: PillAccent?
    public var visual: VoiceVisualKind?

    public init(stillsOnly: Bool = false, slowMotion: Bool = true, accent: PillAccent? = nil, visual: VoiceVisualKind? = nil) {
        self.stillsOnly = stillsOnly
        self.slowMotion = slowMotion
        self.accent = accent
        self.visual = visual
    }
}

/// `SaylarkApp --pill-render <scenario|all> --out <dir>`: renders scenarios to MP4 (120 fps), a 4x
/// slow-motion copy for short ones, and a contact-sheet PNG of the key frames. Prints frame cost.
@MainActor public enum PillRenderCommand {
    public static func run(scenario: String, outDir: URL, envelopeDir: URL, options: PillRenderOptions) -> Bool {
        let envelopes = EnvelopeStore.load(from: envelopeDir)
        if envelopes.isEmpty {
            print("No envelopes in \(envelopeDir.path) (run --pill-envelopes); only the silent card scenarios can render.")
        }
        var all = PillScenarios.all(envelopes)
        if options.accent != nil || options.visual != nil {
            all = all.map { s in
                var s = s
                if s.lanes.count == 1 {
                    if let a = options.accent { s.lanes[0].theme.accent = a }
                    if let v = options.visual { s.lanes[0].theme.visual = v }
                }
                return s
            }
        }
        let names = scenario.split(separator: ",").map(String.init)
        let chosen = scenario == "all" ? all : all.filter { names.contains($0.name) }
        guard !chosen.isEmpty else {
            print("Unknown scenario. Choose from: all, " + all.map(\.name).joined(separator: ", "))
            return false
        }
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var costs: [Double] = []
        var ok = true
        for s in chosen {
            guard let result = render(s, outDir: outDir, options: options) else { ok = false; continue }
            costs += result
        }
        if !costs.isEmpty {
            let line = summary(costs)
            print("pill frame cost over \(costs.count) frames: \(line)")
            try? Data((line + "\n").utf8).write(to: outDir.appendingPathComponent("frame-cost.txt"))
        }
        return ok
    }

    private static func render(_ s: PillScenario, outDir: URL, options: PillRenderOptions) -> [Double]? {
        guard let r = OffscreenRenderer(scenario: s) else { print("\(s.name): no Metal device"); return nil }
        let mp4 = outDir.appendingPathComponent("\(s.name).mp4")
        var encoder: VideoEncoder?
        if !options.stillsOnly {
            do { encoder = try VideoEncoder(output: mp4, width: r.pixelWidth, height: r.pixelHeight, fps: r.fps) } catch {
                print("\(s.name): ffmpeg failed to start: \(error)")
                return nil
            }
        }
        let wanted = Dictionary(s.keyframes.map { (Int(($0.time * r.fps).rounded()), $0.caption) }, uniquingKeysWith: { a, _ in a })
        var stills: [(CGImage, String)] = []
        let crop = cropRect(r, lanes: s.lanes.count)
        let last = wanted.keys.max() ?? 0
        let frames = options.stillsOnly ? last + 1 : r.frameCount
        for i in 0..<frames {
            let pixels = r.renderNextFrame()
            encoder?.write(pixels)
            if let caption = wanted[i], let img = r.image(from: pixels)?.cropping(to: crop) {
                stills.append((img, String(format: "%.3f s  ", Double(i) / r.fps) + caption + "  ·  " + r.state.phase.name))
            }
        }
        if let encoder, !encoder.finish() { print("\(s.name): ffmpeg failed"); return nil }
        var made = options.stillsOnly ? [] : [mp4.lastPathComponent]
        if s.slowMotion, options.slowMotion, !options.stillsOnly {
            let slow = outDir.appendingPathComponent("\(s.name)-slow4x.mp4")
            if VideoEncoder.slowMotion(from: mp4, to: slow, factor: 4) { made.append(slow.lastPathComponent) }
        }
        let sheet = outDir.appendingPathComponent("\(s.name).png")
        if let img = ContactSheet.make(title: s.title, stills: stills, columns: s.lanes.count > 1 ? 3 : 3) {
            writePNG(img, to: sheet)
            made.append(sheet.lastPathComponent)
        }
        print("\(s.name): \(frames) frames  cpu \(summary(r.frameCosts))  wall p99 \(String(format: "%.3f", percentile(r.wallCosts, 0.99))) ms  -> \(made.joined(separator: ", "))")
        return r.frameCosts
    }

    /// The region around the pill(s) worth a still: the lower part of the pill canvas.
    private static func cropRect(_ r: OffscreenRenderer, lanes: Int) -> CGRect {
        let stage = r.stageRectInPixels
        if lanes > 1 { return CGRect(x: stage.midX - 150 * r.scale, y: stage.minY + 100 * r.scale, width: 300 * r.scale, height: stage.height - 120 * r.scale) }
        let h = 150 * r.scale
        return CGRect(x: stage.minX, y: stage.maxY - h, width: stage.width, height: h)
    }

    static func percentile(_ costs: [Double], _ q: Double) -> Double {
        let s = costs.sorted()
        return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))]
    }

    static func summary(_ costs: [Double]) -> String {
        guard !costs.isEmpty else { return "n/a" }
        let s = costs.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int(Double(s.count) * q))] }
        return String(format: "p50 %.3f ms  p95 %.3f ms  p99 %.3f ms  max %.3f ms", p(0.5), p(0.95), p(0.99), s.last!)
    }

    static func writePNG(_ image: CGImage, to url: URL) {
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, image, nil)
        CGImageDestinationFinalize(dst)
    }
}

/// A grid of key frames with captions.
enum ContactSheet {
    static func make(title: String, stills: [(CGImage, String)], columns: Int) -> CGImage? {
        guard let first = stills.first?.0 else { return nil }
        let cw = first.width, ch = first.height
        let cols = min(columns, stills.count), rows = (stills.count + cols - 1) / cols
        let pad = 24, caption = 40, header = 70
        let w = cols * cw + (cols + 1) * pad
        let h = header + rows * (ch + caption + pad) + pad
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(title, in: ctx, at: CGPoint(x: pad, y: h - 46), size: 26, weight: .semibold)
        for (i, (img, text)) in stills.enumerated() {
            let c = i % cols, r = i / cols
            let x = pad + c * (cw + pad)
            let top = h - header - r * (ch + caption + pad)
            ctx.draw(img, in: CGRect(x: x, y: top - ch, width: img.width, height: img.height))
            draw(text, in: ctx, at: CGPoint(x: x + 2, y: top - ch - 30), size: 20, weight: .medium)
        }
        return ctx.makeImage()
    }

    private static func draw(_ s: String, in ctx: CGContext, at p: CGPoint, size: CGFloat, weight: NSFont.Weight) {
        let attr = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                               .foregroundColor: NSColor(white: 0.12, alpha: 1)])
        ctx.textPosition = p
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    }
}
