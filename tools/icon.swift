// Draws the pager icon. Run with a variant name, a pixel size and an output
// path. Everything is derived from the tile size, so every variant is legible
// at sixteen pixels or it does not ship.
//
//   swiftc -O -o /tmp/icon tools/icon.swift -framework Cocoa
//   /tmp/icon corner 512 icon.png
import Cocoa

let lime = NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.0, alpha: 1)
let limeDeep = NSColor(calibratedRed: 0.62, green: 0.83, blue: 0.0, alpha: 1)
let ink = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.075, alpha: 1)
let inkTop = NSColor(calibratedRed: 0.105, green: 0.118, blue: 0.137, alpha: 1)
let slate = NSColor(calibratedRed: 0.26, green: 0.29, blue: 0.33, alpha: 1)

func round(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func draw(_ variant: String, _ side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = side * 0.085
    let tile = NSRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let body = round(tile, tile.width * 0.235)
    let onLime = ["lime", "limebar", "limestack"].contains(variant)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.008), blur: side * 0.03,
                  color: NSColor.black.withAlphaComponent(0.45).cgColor)
    (onLime ? lime : ink).setFill(); body.fill()
    ctx.restoreGState()

    ctx.saveGState(); body.addClip()
    NSGradient(colors: onLime ? [lime, limeDeep] : [inkTop, ink])?.draw(in: tile, angle: -90)

    let m = tile.width * 0.125
    func bar(_ r: NSRect, _ frac: CGFloat, _ colour: NSColor) {
        let h = max(2, r.height * 0.135)
        colour.setFill()
        round(NSRect(x: r.minX, y: r.minY, width: r.width * frac, height: h), h / 2).fill()
    }
    func card(_ r: NSRect, _ fill: NSColor, bar frac: CGFloat? = nil, barColour: NSColor = lime) {
        fill.setFill(); round(r, r.height * 0.26).fill()
        if let frac { bar(r, frac, barColour) }
    }

    switch variant {
    case "corner":
        let w = tile.width * 0.58, h = w * 0.46
        card(NSRect(x: tile.maxX - m - w, y: tile.minY + m, width: w, height: h), slate, bar: 0.66)

    case "lime":
        let w = tile.width * 0.58, h = w * 0.46
        card(NSRect(x: tile.maxX - m - w, y: tile.minY + m, width: w, height: h), ink)

    case "limebar":
        // The panel sits in the corner with room to breathe, and its countdown
        // is inset rather than welded to the bottom edge.
        let w = tile.width * 0.56, h = w * 0.52
        let r = NSRect(x: tile.maxX - m - w, y: tile.minY + m, width: w, height: h)
        ink.setFill(); round(r, r.height * 0.24).fill()
        let pad = r.height * 0.16, bh = max(2, r.height * 0.13)
        lime.setFill()
        round(NSRect(x: r.minX + pad, y: r.minY + pad, width: (r.width - pad * 2) * 0.62, height: bh),
              bh / 2).fill()

    case "corner2":
        let w = tile.width * 0.60, h = w * 0.50
        let r = NSRect(x: tile.maxX - m - w, y: tile.minY + m, width: w, height: h)
        NSColor(calibratedRed: 0.23, green: 0.26, blue: 0.30, alpha: 1).setFill()
        round(r, r.height * 0.24).fill()
        let pad = r.height * 0.16, bh = max(2, r.height * 0.14)
        lime.setFill()
        round(NSRect(x: r.minX + pad, y: r.minY + pad, width: (r.width - pad * 2) * 0.66, height: bh),
              bh / 2).fill()

    case "stack":
        let w = tile.width * 0.62, h = w * 0.27, gap = h * 0.4
        for i in 0..<3 {
            card(NSRect(x: tile.maxX - m - w, y: tile.minY + m + CGFloat(i) * (h + gap),
                        width: w, height: h),
                 slate.withAlphaComponent(1 - CGFloat(i) * 0.28), bar: i == 0 ? 0.7 : nil)
        }

    case "limestack":
        let w = tile.width * 0.62, h = w * 0.27, gap = h * 0.4
        for i in 0..<3 {
            card(NSRect(x: tile.maxX - m - w, y: tile.minY + m + CGFloat(i) * (h + gap),
                        width: w, height: h), ink.withAlphaComponent(1 - CGFloat(i) * 0.3))
        }

    case "cascade":
        let w = tile.width * 0.5, h = w * 0.44
        for i in 0..<3 {
            let step = tile.width * 0.085
            card(NSRect(x: tile.minX + m + CGFloat(2 - i) * step,
                        y: tile.minY + m + CGFloat(i) * step, width: w, height: h),
                 i == 2 ? slate : slate.withAlphaComponent(0.55), bar: i == 2 ? 0.66 : nil)
        }

    case "drain":                                   // the countdown, alone
        let w = tile.width * 0.62, h = tile.height * 0.115
        let r = NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h)
        NSColor.white.withAlphaComponent(0.12).setFill(); round(r, h / 2).fill()
        lime.setFill()
        round(NSRect(x: r.minX, y: r.minY, width: r.width * 0.58, height: h), h / 2).fill()

    case "dot":                                     // a light in the corner
        let d = tile.width * 0.26
        lime.setFill()
        NSBezierPath(ovalIn: NSRect(x: tile.maxX - m - d, y: tile.minY + m, width: d, height: d)).fill()

    case "bracket":                                 // the corner itself
        let arm = tile.width * 0.42, t = tile.width * 0.105
        lime.setFill()
        round(NSRect(x: tile.maxX - m - arm, y: tile.minY + m, width: arm, height: t), t / 2).fill()
        round(NSRect(x: tile.maxX - m - t, y: tile.minY + m, width: t, height: arm), t / 2).fill()

    case "float":                                   // arriving from off screen
        let w = tile.width * 0.66, h = w * 0.44
        card(NSRect(x: tile.maxX - m * 0.2 - w, y: tile.minY + m * 1.4, width: w, height: h),
             slate, bar: 0.6)

    case "duo":                                     // one answered, one waiting
        let w = tile.width * 0.6, h = w * 0.33, gap = h * 0.42
        card(NSRect(x: tile.maxX - m - w, y: tile.minY + m, width: w, height: h), lime)
        card(NSRect(x: tile.maxX - m - w, y: tile.minY + m + h + gap, width: w, height: h), slate)

    case "underline":                               // a full width rule under a panel
        let w = tile.width * 0.66, h = w * 0.4
        let r = NSRect(x: tile.midX - w / 2, y: tile.midY - h * 0.35, width: w, height: h)
        card(r, slate)
        bar(NSRect(x: r.minX, y: r.minY - tile.height * 0.11, width: r.width, height: r.height), 1, lime)

    case "screen":                                  // panel centred, screen framed
        let w = tile.width * 0.62, h = w * 0.44
        card(NSRect(x: tile.midX - w / 2, y: tile.midY - h / 2, width: w, height: h), slate, bar: 0.66)

    default: break
    }
    ctx.restoreGState()
    image.unlockFocus()
    return image
}

let variant = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "corner"
let side = CGFloat(Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "512") ?? 512)
let out = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "/tmp/icon.png"
if let tiff = draw(variant, side).tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: out))
}
