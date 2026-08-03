// render_icon.swift — draws the Mallorca island icon with CoreGraphics and
// writes every required .iconset PNG size. No SVG rasterizer is installed on
// the build machine, so this is the reproducible source that renders the same
// scene described in island.svg.
//
// Usage:  swift render_icon.swift <output.iconset dir>
//
// Produces icon_16x16.png ... icon_512x512@2x.png at the pixel sizes Apple's
// iconutil expects, then `iconutil -c icns` turns the folder into a .icns.
// `just icon` runs both steps.
//
// island.svg describes the scene alone. The margin around it belongs to macOS,
// not to the artwork: an app icon is a rounded square covering ~80.5% of a
// transparent canvas, with a shadow below it, and makeImage() adds that.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func hex(_ h: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((h >> 16) & 0xff) / 255.0,
            green: CGFloat((h >> 8) & 0xff) / 255.0,
            blue: CGFloat(h & 0xff) / 255.0,
            alpha: a)
}

// Draw the scene into a 1024x1024 coordinate space (y-down like the SVG).
// The context is set up flipped so these coordinates match island.svg.
func drawIcon(_ ctx: CGContext) {
    let S: CGFloat = 1024

    func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
        CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
    }
    func fill(_ path: CGPath, _ color: CGColor) {
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath()
    }
    func ellipse(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat, _ color: CGColor) {
        let r = CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2)
        ctx.setFillColor(color); ctx.fillEllipse(in: r)
    }

    // background (deep Orca night) and sky band. Both run to the scene edge:
    // makeImage() clips to the icon's squircle, so painting our own corners
    // here would only fight it and leave gaps where the two disagree.
    fill(roundedRect(0, 0, S, S, 0), hex(0x1a1a1a))
    fill(roundedRect(0, 0, S, 620, 0), hex(0x22242e))

    // sun / moon
    ellipse(760, 250, 90, 90, hex(0xe8d9a8))

    // sea
    fill(roundedRect(0, 600, S, 424, 0), hex(0x2f6f7a))
    fill(roundedRect(0, 600, S, 60, 0), hex(0x3f8b96))
    // re-clip bottom corners to the rounded square by overpainting the mask:
    // simplest is to intersect a rounded-rect clip before sea. Redo with clip:

    // island sand mound
    ellipse(512, 720, 320, 130, hex(0xd9c48a))
    ellipse(512, 700, 230, 95, hex(0xe6d29a))

    // palm trunk
    let trunk = CGMutablePath()
    trunk.move(to: CGPoint(x: 498, y: 700))
    trunk.addCurve(to: CGPoint(x: 450, y: 470), control1: CGPoint(x: 500, y: 620), control2: CGPoint(x: 470, y: 540))
    trunk.addLine(to: CGPoint(x: 500, y: 470))
    trunk.addCurve(to: CGPoint(x: 542, y: 700), control1: CGPoint(x: 520, y: 545), control2: CGPoint(x: 540, y: 625))
    trunk.closeSubpath()
    fill(trunk, hex(0x8a5a34))

    // palm fronds. Each frond mirrors one SVG path:
    //   M start  C c1a c1b tip   L back  Z
    // i.e. a leaf that bows out from the crown to a tip and returns along a
    // straight-ish back edge, giving a curved blade.
    let green = hex(0x3fa66a)
    func curveShape(_ start: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ tip: CGPoint, _ back: CGPoint) {
        let p = CGMutablePath()
        p.move(to: start)
        p.addCurve(to: tip, control1: c1, control2: c2)
        p.addLine(to: back)
        p.closeSubpath()
        fill(p, green)
    }
    // args: start, c1, c2, tip, back
    // left low frond
    curveShape(CGPoint(x: 470, y: 470), CGPoint(x: 380, y: 430), CGPoint(x: 300, y: 440),
               CGPoint(x: 250, y: 480), CGPoint(x: 470, y: 500))
    // right low frond
    curveShape(CGPoint(x: 480, y: 470), CGPoint(x: 560, y: 430), CGPoint(x: 660, y: 440),
               CGPoint(x: 720, y: 480), CGPoint(x: 480, y: 500))
    // up frond
    curveShape(CGPoint(x: 475, y: 470), CGPoint(x: 430, y: 380), CGPoint(x: 420, y: 300),
               CGPoint(x: 450, y: 240), CGPoint(x: 490, y: 470))
    // upper-right frond
    curveShape(CGPoint(x: 478, y: 472), CGPoint(x: 540, y: 400), CGPoint(x: 620, y: 360),
               CGPoint(x: 700, y: 360), CGPoint(x: 490, y: 480))
    // upper-left frond
    curveShape(CGPoint(x: 472, y: 472), CGPoint(x: 410, y: 400), CGPoint(x: 330, y: 360),
               CGPoint(x: 250, y: 360), CGPoint(x: 460, y: 480))
    // crown
    ellipse(476, 466, 22, 22, hex(0x2f8a55))

    // water glints
    let glint = hex(0xbfe3e8, 0.7)
    fill(roundedRect(150, 820, 90, 12, 6), glint)
    fill(roundedRect(760, 860, 120, 12, 6), glint)
    fill(roundedRect(360, 900, 70, 12, 6), glint)
}

// Margin between the canvas edge and the icon body, per canvas size, measured
// off /System/Applications/Utilities/Terminal.app's icns: 824 of 1024, and a
// pixel or two of slack at the sizes too small to spare one.
let margins: [Int: CGFloat] = [16: 1, 32: 3, 64: 6, 128: 12, 256: 25, 512: 50, 1024: 100]

// The corner Apple actually draws is not a circular arc: it is a continuous
// curve that starts bending well before the arc would. Tracing the alpha edge
// of Terminal's, Notes' and Finder's icns (identical to the pixel, all three)
// and fitting a superellipse corner |dx/R|^n + |dy/R|^n = 1 lands on R = 0.3013
// of the body and n = 2.85, within 1.1px rms across the whole edge. A circular
// radius of 185.4, which is what the grid documents, is 3x worse and reads
// visibly tighter at the corners.
let cornerBoxRatio: CGFloat = 0.3013
let cornerExponent: CGFloat = 2.85

func squirclePath(in rect: CGRect) -> CGPath {
    let R = min(rect.width, rect.height) * cornerBoxRatio
    let steps = 96
    // one corner quadrant, from the axis to the diagonal, as (u, v) in 0...1
    let quadrant: [(CGFloat, CGFloat)] = (0...steps).map { i in
        let t = CGFloat(i) / CGFloat(steps) * .pi / 2
        return (pow(cos(t), 2 / cornerExponent), pow(sin(t), 2 / cornerExponent))
    }
    // corner centres and the (u, v) -> offset mapping that walks each corner
    // counter-clockwise into the next edge
    let corners: [(CGPoint, (CGFloat, CGFloat) -> CGPoint)] = [
        (CGPoint(x: rect.maxX - R, y: rect.maxY - R), { CGPoint(x:  $0 * R, y:  $1 * R) }),
        (CGPoint(x: rect.minX + R, y: rect.maxY - R), { CGPoint(x: -$1 * R, y:  $0 * R) }),
        (CGPoint(x: rect.minX + R, y: rect.minY + R), { CGPoint(x: -$0 * R, y: -$1 * R) }),
        (CGPoint(x: rect.maxX - R, y: rect.minY + R), { CGPoint(x:  $1 * R, y: -$0 * R) }),
    ]
    let points = corners.flatMap { centre, offset in
        quadrant.map { u, v in
            CGPoint(x: centre.x + offset(u, v).x, y: centre.y + offset(u, v).y)
        }
    }
    let path = CGMutablePath()
    path.move(to: points[0])
    path.addLines(between: Array(points.dropFirst()))
    path.closeSubpath()
    return path
}

func makeImage(size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high

    let canvas = CGFloat(size)
    let m = margins[size] ?? (canvas * 100.0 / 1024.0).rounded()
    let body = CGRect(x: m, y: m, width: canvas - 2 * m, height: canvas - 2 * m)
    let shape = squirclePath(in: body)

    // Fill the body opaquely to cast the shadow, then draw the scene over it.
    // Below 256px Apple's icons carry no shadow — there is no room for one.
    if size >= 256 {
        ctx.setShadow(offset: CGSize(width: 0, height: -canvas * 0.008),
                      blur: canvas * 0.010,
                      color: CGColor(gray: 0, alpha: 0.32))
        ctx.addPath(shape); ctx.setFillColor(hex(0x1a1a1a)); ctx.fillPath()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }

    // clip everything to the rounded square so sea corners stay rounded
    ctx.addPath(shape); ctx.clip()
    // flip to SVG-style y-down coords, then scale the 1024 scene into the body
    ctx.translateBy(x: body.minX, y: body.maxY)
    ctx.scaleBy(x: body.width / 1024.0, y: -body.height / 1024.0)
    drawIcon(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
guard args.count >= 2 else { fputs("usage: swift render_icon.swift <out.iconset>\n", stderr); exit(1) }
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in specs {
    let img = makeImage(size: px)
    writePNG(img, to: outDir.appendingPathComponent(name))
    print("wrote \(name) (\(px)px)")
}
