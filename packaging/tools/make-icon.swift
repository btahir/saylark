// Turns full-bleed square artwork into a macOS app icon on Apple's grid: the art is masked to the
// continuous-corner rounded square (824 of 1024 pt, radius 185.4), with a soft drop shadow and a
// faint light rim, and written as PNG at the requested pixel size.
//   swiftc -O make-icon.swift -o make-icon && ./make-icon art.png out.png 1024
import AppKit
import QuartzCore

let args = CommandLine.arguments
guard args.count == 4, let art = NSImage(contentsOfFile: args[1]), let px = Int(args[3]) else {
    FileHandle.standardError.write(Data("usage: make-icon <art.png> <out.png> <pixels>\n".utf8)); exit(2)
}
let s = CGFloat(px) / 1024
let canvas = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)

let root = CALayer()
root.frame = canvas
root.isGeometryFlipped = false

// Shadow: drawn by a layer the shape of the body, behind it.
let shadow = CALayer()
shadow.frame = body
shadow.cornerRadius = 185.4 * s
shadow.cornerCurve = .continuous
shadow.backgroundColor = CGColor(gray: 0, alpha: 1)
shadow.shadowColor = CGColor(gray: 0, alpha: 1)
shadow.shadowOpacity = 0.3
shadow.shadowRadius = 14 * s
shadow.shadowOffset = CGSize(width: 0, height: -8 * s)
root.addSublayer(shadow)

let tile = CALayer()
tile.frame = body
tile.cornerRadius = 185.4 * s
tile.cornerCurve = .continuous
tile.masksToBounds = true
tile.contents = art.cgImage(forProposedRect: nil, context: nil, hints: nil)
tile.contentsGravity = .resizeAspectFill
root.addSublayer(tile)

// A faint rim: light at the top edge, gone by the middle, like the system icons' edge highlight.
let rim = CAShapeLayer()
rim.frame = body
let inset = 1.5 * s
rim.path = CGPath(roundedRect: CGRect(x: inset, y: inset, width: body.width - 2 * inset, height: body.height - 2 * inset),
                  cornerWidth: 183 * s, cornerHeight: 183 * s, transform: nil)
rim.fillColor = nil
rim.strokeColor = CGColor(gray: 1, alpha: 1)
rim.lineWidth = 2 * s
let fade = CAGradientLayer()
fade.frame = CGRect(origin: .zero, size: body.size)
fade.colors = [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0.0)]
fade.startPoint = CGPoint(x: 0.5, y: 1)
fade.endPoint = CGPoint(x: 0.5, y: 0.45)
rim.mask = fade
root.addSublayer(rim)

guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
root.render(in: ctx)
guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
