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

/// The level, as a log line shows it: a short tag, coloured only when it matters.
struct AmbientLevelTag: View {
    let severity: String?

    private var look: (text: String, color: Color, fill: Bool) {
        switch Severity(rawValue: severity ?? "info") ?? .info {
        case .debug: return ("DBG", AmbientTheme.faint, false)
        case .info: return ("INF", AmbientTheme.faint, false)
        case .notice: return ("NTC", AmbientTheme.dim, false)
        case .warn: return ("WRN", AmbientTheme.amber, true)
        case .error: return ("ERR", AmbientTheme.red, true)
        case .critical: return ("CRT", AmbientTheme.red, true)
        }
    }

    var body: some View {
        let l = look
        Text(l.text)
            .font(AmbientTheme.mono(9.5, .semibold))
            .foregroundColor(l.color)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 3).fill(l.fill ? l.color.opacity(0.18) : Color.white.opacity(0.05)))
            .frame(width: 30, alignment: .leading)
    }
}

/// A square icon button, all the same size, lit on hover.
struct AmbientIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = AmbientTheme.dim
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .foregroundColor(hover ? AmbientTheme.text : tint)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hover ? AmbientTheme.raisedHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

/// One event as a log line: time, level, mark, source, message.
struct AmbientEventRow: View {
    @ObservedObject var store: AmbientStore
    let event: AmbientEvent
    var sourceWidth: CGFloat = 84

    var body: some View {
        let look = AmbientRules.resolve(event, store.settings)
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if let at = event.happened {
                AmbientAge(since: at, fontSize: 12).frame(width: 24, alignment: .leading)
            }
            AmbientLevelTag(severity: event.severity)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let brand = look.brand {
                    AmbientMark(brand: brand, color: Color(hex: look.sourceColor) ?? AmbientTheme.dim, size: 11)
                }
                Text(store.label(for: event)).foregroundColor(AmbientTheme.dim).lineLimit(1)
            }
            .frame(width: sourceWidth, alignment: .leading)
            StyledMessage(text: event.text, color: Color(hex: look.accent) ?? AmbientTheme.text, fontSize: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(event.dismissedAt == nil ? 1 : 0.45)
        }
        .font(.system(size: 12))
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

/// A pause button that opens its choices as a native menu.
struct AmbientPauseMenu: View {
    let paused: Bool
    let actions: AmbientMenuActions
    @State private var hover = false

    var body: some View {
        if paused {
            AmbientIconButton(symbol: "play.fill", help: "Resume", tint: AmbientTheme.lime) { actions.resume() }
        } else {
            Menu {
                Button("For 15 minutes") { actions.pause(Date().addingTimeInterval(15 * 60)) }
                Button("For 1 hour") { actions.pause(Date().addingTimeInterval(60 * 60)) }
                Button("Until tomorrow, 9:00") { actions.pause(AmbientRules.tomorrowMorning()) }
            } label: {
                Image(systemName: "pause.fill")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 26, height: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hover ? AmbientTheme.raisedHover : Color.clear))
            .onHover { hover = $0 }
            .help("Pause")
        }
    }
}

struct AmbientMenuView: View {
    @ObservedObject var store: AmbientStore
    let actions: AmbientMenuActions
    var middleClickNeedsPermission: Bool

    private var connections: [AmbientConnection] { store.activeConnections }

    private var status: (text: String, color: Color) {
        if store.paused {
            if let until = store.pausedUntil {
                let clock = DateFormatter()
                clock.dateFormat = Calendar.current.isDateInToday(until) ? "HH:mm" : "EEE HH:mm"
                return ("paused until \(clock.string(from: until))", AmbientTheme.amber)
            }
            return ("paused", AmbientTheme.amber)
        }
        if connections.isEmpty { return ("local", AmbientTheme.dim) }
        let live = connections.filter { store.phases[$0.id] == "connected" }.count
        if live == connections.count { return ("live", AmbientTheme.lime) }
        if live > 0 { return ("\(live)/\(connections.count) live", AmbientTheme.amber) }
        return ("reconnecting", AmbientTheme.amber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 10).padding(.vertical, 5)
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
            recent.padding(.horizontal, 10).padding(.vertical, 5)
            if middleClickNeedsPermission {
                Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
                permission.padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .frame(width: 400)
        .font(.system(size: 12))
        .background(AmbientTheme.ink)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: AmbientIcon.image(paused: store.paused, size: 15)).renderingMode(.template)
                .foregroundColor(AmbientTheme.text)
            Text("Ambient").font(.system(size: 12, weight: .semibold)).foregroundColor(AmbientTheme.text)
            HStack(spacing: 5) {
                Circle().fill(status.color).frame(width: 5, height: 5)
                Text(status.text).foregroundColor(status.color)
            }
            .help(connections.map { "\($0.name): \(store.phases[$0.id] ?? "idle") \u{00B7} \($0.url)" }.joined(separator: "\n"))
            Spacer(minLength: 4)
            AmbientPauseMenu(paused: store.paused, actions: actions)
            AmbientIconButton(symbol: "list.bullet.rectangle", help: "Event log") { actions.openLog() }
            AmbientIconButton(symbol: "gearshape", help: "Settings") { actions.openSettings() }
            AmbientIconButton(symbol: "power", help: "Quit Ambient") { actions.quit() }
        }
    }

    private var recent: some View {
        let events = Array(store.history.prefix(8))
        return VStack(alignment: .leading, spacing: 1) {
            if events.isEmpty {
                Text("Nothing yet").foregroundColor(AmbientTheme.faint).padding(.vertical, 4)
            }
            ForEach(events, id: \.key) { event in
                AmbientEventRow(store: store, event: event, sourceWidth: 80)
            }
        }
    }

    private var permission: some View {
        HStack(spacing: 7) {
            Image(systemName: "computermouse").foregroundColor(AmbientTheme.amber)
            Text("Middle-click also reaches the app below").foregroundColor(AmbientTheme.dim)
            Spacer(minLength: 4)
            Button("Allow\u{2026}") { actions.allowMiddleClick() }
                .buttonStyle(.plain).foregroundColor(AmbientTheme.lime)
        }
    }
}
