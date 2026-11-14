import AppKit
import CoreText

/// Pre-rendered text and SF Symbol bitmaps for the pill's layers. Rendering text once and reusing the
/// bitmap keeps per-frame work to setting layer properties. Cached by content.
@MainActor final class TextImages {
    struct Rendered {
        let image: CGImage
        /// Size in points.
        let size: CGSize
        /// Exact typographic width, for laying words out with true spacing.
        var advance: CGFloat = 0
    }

    /// A cached bitmap and when it was last used (a counter, not a clock).
    private final class Entry {
        let rendered: Rendered
        var used: UInt64
        init(_ rendered: Rendered, used: UInt64) { self.rendered = rendered; self.used = used }
    }

    private var cache: [String: Entry] = [:]
    private var tick: UInt64 = 0
    /// Most entries kept. Live words add a bitmap per distinct word and cards one per take text, so
    /// without a bound the cache grows all day. Over the limit, the least recently used quarter goes.
    static let limit = 400
    let scale: CGFloat

    var count: Int { cache.count }

    private func hit(_ key: String) -> Rendered? {
        guard let e = cache[key] else { return nil }
        tick += 1
        e.used = tick
        return e.rendered
    }

    private func store(_ key: String, _ r: Rendered) {
        tick += 1
        cache[key] = Entry(r, used: tick)
        if cache.count > Self.limit {
            let oldest = cache.sorted { $0.value.used < $1.value.used }.prefix(Self.limit / 4)
            for (k, _) in oldest { cache[k] = nil }
        }
    }

    init(scale: CGFloat) {
        self.scale = scale
    }

    /// One line of text. `monoDigits` keeps the timer from jittering as digits change.
    func line(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: CGColor, monoDigits: Bool = false) -> Rendered {
        let key = "L|\(string)|\(size)|\(weight.rawValue)|\(color.components ?? [])|\(monoDigits)"
        if let r = hit(key) { return r }
        let font = monoDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attr = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white])
        let line = CTLineCreateWithAttributedString(attr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let pts = CGSize(width: ceil(width), height: ceil(ascent + descent))
        let image = draw(pts) { ctx in
            ctx.textPosition = CGPoint(x: 0, y: descent)
            CTLineDraw(line, ctx)
        }
        let r = Rendered(image: image, size: pts, advance: width)
        store(key, r)
        return r
    }

    /// Wrapped text up to `maxLines`, ending in an ellipsis when it doesn't fit.
    func paragraph(_ string: String, size: CGFloat, width: CGFloat, maxLines: Int, color: CGColor) -> Rendered {
        let key = "P|\(string)|\(size)|\(width)|\(maxLines)|\(color.components ?? [])"
        if let r = hit(key) { return r }
        let font = NSFont.systemFont(ofSize: size)
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.08
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white, .paragraphStyle: style]
        let typesetter = CTTypesetterCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
        let text = string as NSString
        var lines: [CTLine] = []
        var start = 0
        while start < text.length, lines.count < maxLines {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
            if lines.count == maxLines - 1, start + count < text.length {
                // Last allowed line: truncate the rest with an ellipsis.
                count = text.length - start
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(string: "\u{2026}", attributes: attrs))
                lines.append(CTLineCreateTruncatedLine(rest, Double(width), .end, ellipsis) ?? rest)
                break
            }
            lines.append(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count)))
            start += count
        }
        let lineHeight = ceil((font.ascender - font.descender + font.leading) * 1.08)
        let pts = CGSize(width: width, height: lineHeight * CGFloat(lines.count))
        let image = draw(pts) { ctx in
            for (i, line) in lines.enumerated() {
                ctx.textPosition = CGPoint(x: 0, y: pts.height - lineHeight * CGFloat(i + 1) - font.descender + (lineHeight - (font.ascender - font.descender)) / 2)
                CTLineDraw(line, ctx)
            }
        }
        let r = Rendered(image: image, size: pts)
        store(key, r)
        return r
    }

    /// An SF Symbol tinted with one colour.
    func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .semibold, color: CGColor) -> Rendered {
        let key = "S|\(name)|\(size)|\(weight.rawValue)|\(color.components ?? [])"
        if let r = hit(key) { return r }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(cgColor: color) ?? .white]))
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return line("?", size: size, color: color)
        }
        let pts = CGSize(width: ceil(base.size.width), height: ceil(base.size.height))
        let image = draw(pts) { ctx in
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            base.draw(in: CGRect(origin: .zero, size: pts))
            NSGraphicsContext.restoreGraphicsState()
        }
        let r = Rendered(image: image, size: pts)
        store(key, r)
        return r
    }

    private func draw(_ pts: CGSize, _ body: (CGContext) -> Void) -> CGImage {
        let w = max(1, Int(ceil(pts.width * scale))), h = max(1, Int(ceil(pts.height * scale)))
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldSmoothFonts(false)
        body(ctx)
        return ctx.makeImage()!
    }
}
