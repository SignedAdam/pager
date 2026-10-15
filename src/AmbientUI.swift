import AppKit
import SwiftUI

// MARK: - ambient: the look of its windows, and the menu bar
//
// One small design system for everything Ambient puts on screen besides the
// overlay: ink background, hairlines, three greys, Pager's lime as the only
// accent. The menu bar item opens a panel (not a plain NSMenu) with the
// stream's state, the last few events, pauses and the way to the log.

enum AmbientTheme {
    static let ink = Color(red: 0.055, green: 0.063, blue: 0.075)
    static let raised = Color.white.opacity(0.045)
    static let raisedHover = Color.white.opacity(0.08)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let dim = Color.white.opacity(0.58)
    static let faint = Color.white.opacity(0.36)
    static let lime = Color(red: 0.78, green: 1.0, blue: 0.0)
    static let amber = Color(red: 1.0, green: 0.70, blue: 0.25)
    static let red = Color(red: 1.0, green: 0.37, blue: 0.34)
    static let nsInk = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.075, alpha: 1)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: icon

/// The mark: the top-right corner of a screen, and the stream living in it.
/// A bracket for the corner, three lines tucked against it, newest and
/// longest on top, fading as they age. Paused, a pause sign takes the lines'
/// place inside the same corner, so the silhouette stays put.
enum AmbientIcon {
    static func image(paused: Bool = false, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let s = rect.width / 18
            let ink = NSColor.black
            // The corner: along the top and down the right side, softly rounded.
            let corner = NSBezierPath()
            corner.move(to: NSPoint(x: 2.2 * s, y: 1.6 * s))
            corner.line(to: NSPoint(x: 13.0 * s, y: 1.6 * s))
            corner.curve(to: NSPoint(x: 16.4 * s, y: 5.0 * s),
                         controlPoint1: NSPoint(x: 15.0 * s, y: 1.6 * s), controlPoint2: NSPoint(x: 16.4 * s, y: 3.0 * s))
            corner.line(to: NSPoint(x: 16.4 * s, y: 15.8 * s))
            corner.lineWidth = 1.6 * s
            corner.lineCapStyle = .round
            ink.withAlphaComponent(paused ? 0.55 : 0.85).setStroke()
            corner.stroke()
            let end: CGFloat = 13.4, thickness: CGFloat = 2.2
            if paused {
                ink.setFill()
                for x in [5.6, 9.4] as [CGFloat] {
                    NSBezierPath(roundedRect: NSRect(x: x * s, y: 6.0 * s, width: 2.6 * s, height: 7.0 * s),
                                 xRadius: 0.9 * s, yRadius: 0.9 * s).fill()
                }
            } else {
                for (y, start, alpha) in [(5.6, 3.4, 1.0), (9.6, 6.4, 0.78), (13.6, 9.2, 0.58)] as [(CGFloat, CGFloat, CGFloat)] {
                    ink.withAlphaComponent(alpha).setFill()
                    let bar = NSRect(x: start * s, y: (y - thickness / 2) * s, width: (end - start) * s, height: thickness * s)
                    NSBezierPath(roundedRect: bar, xRadius: thickness / 2 * s, yRadius: thickness / 2 * s).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "Ambient, paused" : "Ambient"
        return image
    }
}

// MARK: shared pieces

/// A quiet button: text on a faint surface that lights on hover.
struct AmbientButtonStyle: ButtonStyle {
    var prominent = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        AmbientButtonBody(configuration: configuration, prominent: prominent, compact: compact)
    }
}

private struct AmbientButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let prominent: Bool
    let compact: Bool
    @State private var hover = false

    var body: some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: prominent ? .semibold : .medium))
            .foregroundColor(prominent ? .black : (hover ? AmbientTheme.text : AmbientTheme.text.opacity(0.85)))
            .padding(.horizontal, compact ? 9 : 11)
            .padding(.vertical, compact ? 4 : 6)
            .frame(maxWidth: compact ? nil : .infinity)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? AmbientTheme.lime.opacity(configuration.isPressed ? 0.75 : (hover ? 1 : 0.9))
                                    : (hover || configuration.isPressed ? AmbientTheme.raisedHover : AmbientTheme.raised)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(prominent ? Color.clear : AmbientTheme.hairline))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

struct AmbientSectionTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack {
            Text(text.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.8)
                .foregroundColor(AmbientTheme.faint)
            Spacer()
            if let trailing { Text(trailing).font(AmbientTheme.mono(9.5)).foregroundColor(AmbientTheme.faint) }
        }
    }
}

/// A coloured dot with a soft glow, for live states.
struct AmbientStatusDot: View {
    let color: Color
    var glow = true

    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .shadow(color: glow ? color.opacity(0.7) : .clear, radius: 3)
    }
}

/// One event as a compact row: mark, source, message, age.
struct AmbientEventRow: View {
    @ObservedObject var store: AmbientStore
    let event: AmbientEvent
    var sourceWidth: CGFloat = 84
    var lineLimit = 1
    var showContext = true

    var body: some View {
        let look = AmbientRules.resolve(event, store.settings)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                if let brand = look.brand {
                    AmbientMark(brand: brand, color: Color(hex: look.sourceColor) ?? AmbientTheme.dim, size: 11.5)
                }
                Text(store.label(for: event)).font(.system(size: 11.5))
                    .foregroundColor(AmbientTheme.dim).lineLimit(1)
            }
            .frame(width: sourceWidth, alignment: .leading)
            StyledMessage(text: event.text, context: showContext ? (event.subject.map { $0 + "  " } ?? "") : "",
                          color: Color(hex: look.accent) ?? AmbientTheme.text, fontSize: 11.5, lineLimit: lineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let at = event.happened {
                AmbientAge(since: at, fontSize: 12)
            }
        }
        .opacity(event.dismissedAt == nil ? 1 : 0.45)
    }
}

// MARK: - the menu bar panel

struct AmbientMenuActions {
    var pause: (Date) -> Void
    var resume: () -> Void
    var openLog: () -> Void
    var openSettings: () -> Void
    var allowMiddleClick: () -> Void
    var quit: () -> Void
}

struct AmbientMenuView: View {
    @ObservedObject var store: AmbientStore
    let actions: AmbientMenuActions
    var middleClickNeedsPermission: Bool

    private var connections: [AmbientConnection] { store.activeConnections }

    private var status: (text: String, color: Color, glow: Bool) {
        if store.paused {
            if let until = store.pausedUntil {
                let clock = DateFormatter()
                clock.dateFormat = Calendar.current.isDateInToday(until) ? "HH:mm" : "EEE HH:mm"
                return ("Paused until \(clock.string(from: until))", AmbientTheme.amber, false)
            }
            return ("Paused", AmbientTheme.amber, false)
        }
        if connections.isEmpty { return ("Local", AmbientTheme.dim, false) }
        let live = connections.filter { store.phases[$0.id] == "connected" }.count
        if live == connections.count { return ("Live", AmbientTheme.lime, true) }
        if live > 0 { return ("\(live) of \(connections.count) live", AmbientTheme.amber, true) }
        return ("Reconnecting", AmbientTheme.amber, false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 13).padding(.bottom, 11)
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
            recent.padding(.horizontal, 14).padding(.vertical, 11)
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
            pause.padding(.horizontal, 14).padding(.vertical, 11)
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
            footer.padding(.horizontal, 14).padding(.vertical, 11)
        }
        .frame(width: 340)
        .background(AmbientTheme.ink)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(nsImage: AmbientIcon.image(paused: store.paused, size: 16)).renderingMode(.template)
                    .foregroundColor(AmbientTheme.text)
                Text("Ambient").font(.system(size: 13, weight: .semibold)).foregroundColor(AmbientTheme.text)
                Spacer()
                HStack(spacing: 6) {
                    AmbientStatusDot(color: status.color, glow: status.glow)
                    Text(status.text).font(.system(size: 11, weight: .medium)).foregroundColor(status.color)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(status.color.opacity(0.12)))
            }
            ForEach(connections) { connection in
                let phase = store.phases[connection.id] ?? "idle"
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 10))
                        .foregroundColor(AmbientTheme.faint)
                    Text(connection.name).font(.system(size: 11.5)).foregroundColor(AmbientTheme.dim)
                    Text(URLComponents(string: connection.url)?.host ?? connection.url)
                        .font(AmbientTheme.mono(10.5)).foregroundColor(AmbientTheme.faint).lineLimit(1)
                    Spacer()
                    if phase != "connected" {
                        Text(phase).font(.system(size: 10.5)).foregroundColor(AmbientTheme.amber).lineLimit(1)
                    }
                }
            }
        }
    }

    private var recent: some View {
        let events = Array(store.history.prefix(5))
        return VStack(alignment: .leading, spacing: 7) {
            AmbientSectionTitle(text: "Recent", trailing: store.history.isEmpty ? nil : "\(store.history.count) in log")
            if events.isEmpty {
                Text("Nothing yet. Lines arrive from your hubs and `pager event`.")
                    .font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events, id: \.key) { event in
                    AmbientEventRow(store: store, event: event, sourceWidth: 74, lineLimit: 2, showContext: false)
                }
            }
        }
    }

    private var pause: some View {
        VStack(alignment: .leading, spacing: 8) {
            AmbientSectionTitle(text: "Quiet for")
            HStack(spacing: 6) {
                Button("15 min") { actions.pause(Date().addingTimeInterval(15 * 60)) }
                Button("1 hour") { actions.pause(Date().addingTimeInterval(60 * 60)) }
                Button("Until 9:00") { actions.pause(AmbientRules.tomorrowMorning()) }
                    .help("Quiet until 9:00 tomorrow")
            }
            .lineLimit(1)
            .buttonStyle(AmbientButtonStyle())
            if store.paused {
                Button { actions.resume() } label: {
                    Label("Resume the stream", systemImage: "play.fill")
                }
                .buttonStyle(AmbientButtonStyle(prominent: true))
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if middleClickNeedsPermission {
                HStack(alignment: .center, spacing: 9) {
                    Image(systemName: "computermouse").font(.system(size: 12)).foregroundColor(AmbientTheme.amber)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Middle-click also hits the app below").font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(AmbientTheme.text)
                        Text("Allow Accessibility to fix it").font(.system(size: 11))
                            .foregroundColor(AmbientTheme.dim)
                    }
                    Spacer(minLength: 4)
                    Button("Allow") { actions.allowMiddleClick() }.buttonStyle(AmbientButtonStyle(compact: true))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AmbientTheme.amber.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(AmbientTheme.amber.opacity(0.18)))
            }
            HStack(spacing: 6) {
                Button { actions.openLog() } label: { Label("Event log", systemImage: "list.bullet.rectangle") }
                Button { actions.openSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                Button { actions.quit() } label: { Image(systemName: "power") }
                    .buttonStyle(AmbientButtonStyle(compact: true)).help("Quit Ambient")
            }
            .buttonStyle(AmbientButtonStyle())
        }
    }
}
