import AppKit
import CoreText
import ImageIO

/// Realistic screens for the pill to float over in renders: a chat app (light and dark), a dark
/// code editor and a busy wallpaper. Drawn with Core Graphics; generic content, no real brands.
public enum Backdrop: String, CaseIterable, Sendable {
    case chatLight, chatDark, editorDark, wallpaper

    public var isDark: Bool { self != .chatLight }

    /// Draws the backdrop at `size` points and `scale` pixels per point.
    @MainActor public func image(size: CGSize, scale: CGFloat) -> CGImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        // Draw top-down like a screen.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let d = Drawer(ctx: ctx, size: size)
        switch self {
        case .chatLight: d.chat(dark: false)
        case .chatDark: d.chat(dark: true)
        case .editorDark: d.editor()
        case .wallpaper: d.wallpaper()
        }
        return ctx.makeImage()!
    }
}

private struct Drawer {
    let ctx: CGContext
    let size: CGSize

    func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    func fill(_ r: CGRect, _ c: CGColor, radius: CGFloat = 0) {
        ctx.setFillColor(c)
        if radius > 0 {
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        } else {
            ctx.fill(r)
        }
    }

    func stroke(_ r: CGRect, _ c: CGColor, radius: CGFloat, width: CGFloat = 1) {
        ctx.setStrokeColor(c)
        ctx.setLineWidth(width)
        ctx.addPath(CGPath(roundedRect: r.insetBy(dx: width / 2, dy: width / 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
    }

    /// Text in a flipped (top-down) context. `y` is the top of the line box.
    func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: CGColor, weight: NSFont.Weight = .regular, mono: Bool = false, width: CGFloat? = nil) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if let width {
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let lineH = ceil(font.ascender - font.descender + font.leading) + 4
            var start = 0, line = 0
            let ns = s as NSString
            let typesetter = CTFramesetterGetTypesetter(setter)
            while start < ns.length {
                let n = CTTypesetterSuggestLineBreak(typesetter, start, Double(width))
                let l = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: n))
                ctx.textPosition = CGPoint(x: x, y: y + font.ascender + CGFloat(line) * lineH)
                CTLineDraw(l, ctx)
                start += n; line += 1
            }
        } else {
            ctx.textPosition = CGPoint(x: x, y: y + font.ascender)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        ctx.restoreGState()
    }

    func windowChrome(_ bar: CGColor, dark: Bool) {
        fill(CGRect(x: 0, y: 0, width: size.width, height: 38), bar)
        for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(rgb(UInt32(c), dark ? 0.9 : 1))
            ctx.fillEllipse(in: CGRect(x: 14 + CGFloat(i) * 20, y: 13, width: 12, height: 12))
        }
    }

    func chat(dark: Bool) {
        let bg = dark ? rgb(0x262624) : rgb(0xFAF9F5)
        let side = dark ? rgb(0x1F1E1D) : rgb(0xF2F0E8)
        let ink = dark ? rgb(0xECEAE3) : rgb(0x2B2A27)
        let soft = dark ? rgb(0xA6A39A) : rgb(0x77746B)
        let bubble = dark ? rgb(0x141413) : rgb(0xEDEAE0)
        let line = dark ? rgb(0xFFFFFF, 0.08) : rgb(0x000000, 0.08)
        fill(CGRect(origin: .zero, size: size), bg)
        fill(CGRect(x: 0, y: 0, width: 190, height: size.height), side)
        windowChrome(side, dark: dark)
        text("New chat", x: 16, y: 52, size: 13, color: ink, weight: .medium)
        let recents = ["Release checklist", "Fix flaky upload test", "Pricing page copy", "Postgres backups", "Launch video ideas", "Onboarding steps", "Icon round two"]
        text("Recents", x: 16, y: 88, size: 11, color: soft, weight: .medium)
        for (i, r) in recents.enumerated() {
            if i == 1 { fill(CGRect(x: 8, y: 106 + CGFloat(i) * 28, width: 174, height: 26), dark ? rgb(0xFFFFFF, 0.06) : rgb(0x000000, 0.05), radius: 7) }
            text(r, x: 16, y: 110 + CGFloat(i) * 28, size: 13, color: ink)
        }
        fill(CGRect(x: 190, y: 0, width: 1, height: size.height), line)

        let col = CGRect(x: 250, y: 60, width: 500, height: size.height)
        let q = "Can you check why the upload test fails only on CI?"
        fill(CGRect(x: col.maxX - 330, y: col.minY, width: 330, height: 40), bubble, radius: 14)
        text(q, x: col.maxX - 316, y: col.minY + 11, size: 13, color: ink)
        let a = "The test waits for the file watcher, but CI runs on a slower disk, so the event arrives after the 2-second timeout. Two options: raise the timeout for CI only, or wait on the upload's completion callback instead of the watcher. The second is more reliable and makes the test faster on every machine."
        text(a, x: col.minX, y: col.minY + 64, size: 13.5, color: ink, width: col.width)
        let b = "I'd go with the callback. Want me to make the change and run the suite?"
        text(b, x: col.minX, y: col.minY + 160, size: 13.5, color: ink, width: col.width)

        // Composer at the bottom, where the pill usually lands.
        let comp = CGRect(x: col.minX - 10, y: size.height - 132, width: col.width + 20, height: 96)
        fill(comp, dark ? rgb(0x30302E) : rgb(0xFFFFFF), radius: 18)
        stroke(comp, dark ? rgb(0xFFFFFF, 0.1) : rgb(0x000000, 0.1), radius: 18)
        text("Reply...", x: comp.minX + 18, y: comp.minY + 16, size: 14, color: soft)
        fill(CGRect(x: comp.maxX - 46, y: comp.maxY - 44, width: 32, height: 32), dark ? rgb(0xFFFFFF, 0.14) : rgb(0x000000, 0.12), radius: 9)
    }

    func editor() {
        let bg = rgb(0x1E1F22), gutter = rgb(0x1E1F22), side = rgb(0x18191B)
        fill(CGRect(origin: .zero, size: size), bg)
        fill(CGRect(x: 0, y: 0, width: 200, height: size.height), side)
        windowChrome(side, dark: true)
        let files = ["Sources", "  App", "    AppDelegate.swift", "    Settings.swift", "  Pill", "    PillView.swift", "    Spring.swift", "Tests", "Package.swift", "README.md"]
        for (i, f) in files.enumerated() {
            if i == 5 { fill(CGRect(x: 6, y: 50 + CGFloat(i) * 22, width: 188, height: 22), rgb(0x2E436E, 0.7), radius: 5) }
            text(f, x: 14, y: 53 + CGFloat(i) * 22, size: 12.5, color: rgb(i == 5 ? 0xFFFFFF : 0xB8BCC4))
        }
        fill(CGRect(x: 200, y: 0, width: size.width - 200, height: 34), rgb(0x18191B))
        fill(CGRect(x: 200, y: 0, width: 150, height: 34), bg)
        text("PillView.swift", x: 218, y: 10, size: 12, color: rgb(0xDFE1E5))
        let code: [[(String, UInt32)]] = [
            [("import", 0xCF8E6D), (" QuartzCore", 0xBCBEC4)],
            [],
            [("/// Steps every spring and applies the result.", 0x7A7E85)],
            [("func", 0xCF8E6D), (" update", 0x56A8F5), ("(state: ", 0xBCBEC4), ("PillState", 0x16BAAC), (", dt: ", 0xBCBEC4), ("Double", 0x16BAAC), (") {", 0xBCBEC4)],
            [("    let", 0xCF8E6D), (" level = meter.", 0xBCBEC4), ("update", 0x56A8F5), ("(rms: rms, dt: dt)", 0xBCBEC4)],
            [("    history.", 0xBCBEC4), ("push", 0x56A8F5), ("(level)", 0xBCBEC4)],
            [("    retarget", 0x56A8F5), ("(state: state)", 0xBCBEC4)],
            [("    for", 0xCF8E6D), (" s ", 0xBCBEC4), ("in", 0xCF8E6D), (" springs { s.", 0xBCBEC4), ("step", 0x56A8F5), ("(dt) }", 0xBCBEC4)],
            [("    if", 0xCF8E6D), (" state.phase == .", 0xBCBEC4), ("hidden", 0xC77DBB), (" {", 0xBCBEC4)],
            [("        return", 0xCF8E6D), (" stopDisplayLink", 0x56A8F5), ("()", 0xBCBEC4)],
            [("    }", 0xBCBEC4)],
            [("    apply", 0x56A8F5), ("(time: ", 0xBCBEC4), ("CACurrentMediaTime", 0x56A8F5), ("())", 0xBCBEC4)],
            [("}", 0xBCBEC4)],
            [],
            [("private func", 0xCF8E6D), (" snap", 0x56A8F5), ("(_ r: ", 0xBCBEC4), ("CGRect", 0x16BAAC), (") -> ", 0xBCBEC4), ("CGRect", 0x16BAAC), (" {", 0xBCBEC4)],
            [("    CGRect", 0x16BAAC), ("(x: (r.minX * scale).", 0xBCBEC4), ("rounded", 0x56A8F5), ("() / scale, y: r.minY,", 0xBCBEC4)],
            [("           width: r.width, height: r.height)", 0xBCBEC4)],
            [("}", 0xBCBEC4)],
        ]
        for (i, row) in code.enumerated() {
            let y = 48 + CGFloat(i) * 20
            text(String(i + 1), x: 214, y: y, size: 12, color: rgb(0x4B5059), mono: true)
            var x: CGFloat = 252
            for (s, c) in row {
                text(s, x: x, y: y, size: 12.5, color: rgb(c), mono: true)
                x += CGFloat(s.count) * 7.52
            }
        }
        _ = gutter
        fill(CGRect(x: 200, y: size.height - 24, width: size.width - 200, height: 24), rgb(0x2B2D30))
        text("main   Swift   Ln 7, Col 33   UTF-8", x: 214, y: size.height - 19, size: 11, color: rgb(0x9DA0A8))
    }

    func wallpaper() {
        let path = "/System/Library/Desktop Pictures/Sonoma.heic"
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 2400] as CFDictionary) {
            // Crop a 16:10 band from the lower middle, where the hills are busiest.
            let iw = CGFloat(img.width), ih = CGFloat(img.height)
            let cropH = iw * size.height / size.width
            let crop = CGRect(x: 0, y: ih * 0.42, width: iw, height: min(cropH, ih * 0.58))
            if let part = img.cropping(to: crop) {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: size.height)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(part, in: CGRect(origin: .zero, size: size))
                ctx.restoreGState()
                return
            }
        }
        // Fallback: busy procedural stripes.
        for i in 0..<40 {
            fill(CGRect(x: CGFloat(i) * 20, y: 0, width: 20, height: size.height), rgb(UInt32(0x203040 + i * 0x050307 % 0xFFFFFF)))
        }
    }
}
