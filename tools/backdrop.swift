// A full screen backdrop, so screenshots of panels never contain the desktop.
// It sits below the panel level, so panels float over it exactly as they do
// over anything else, blur and shadow included.
import Cocoa

final class Gradient: NSView {
    override func draw(_ rect: NSRect) {
        NSGradient(colors: [
            NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.075, alpha: 1),
            NSColor(calibratedRed: 0.098, green: 0.110, blue: 0.126, alpha: 1),
            NSColor(calibratedRed: 0.063, green: 0.078, blue: 0.071, alpha: 1),
        ])?.draw(in: bounds, angle: 118)
        NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.0, alpha: 0.04).setFill()
        NSBezierPath(ovalIn: NSRect(x: bounds.width * 0.5, y: -bounds.height * 0.4,
                                    width: bounds.width * 0.9, height: bounds.height * 1.2)).fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main ?? NSScreen.screens[0]
let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                      backing: .buffered, defer: false)
// Just below the panels, so floating overlays and menu bars from other apps
// cannot show through into a screenshot. Pass "low" to sit beneath ordinary
// windows instead, which is what shooting the log window needs.
let low = CommandLine.arguments.contains("low")
window.level = low
    ? NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
window.isOpaque = true
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary]
window.contentView = Gradient()
window.setFrame(screen.frame, display: true)
window.orderFrontRegardless()
app.run()
