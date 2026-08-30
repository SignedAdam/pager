// pager: a floating notification panel for macOS.
//
//   pager --title "Deploy failed" --source acme --accent "#ff5f57" \
//         --chip "production" --chip "8f21ac3" \
//         --action "Logs:open https://…" --action "Rollback:./rollback.sh"
//
// It knows nothing about whatever raised it. Everything is a flag, so anything
// that can run a shell command can raise one. To add a button, append another
// --action. To add a field, add a flag and one line in Options.parse.
//
// The panel is a non-activating NSPanel: it floats over everything including
// full screen spaces, can never become the key window, and therefore can never
// take a keystroke away from whatever you are typing.

import AVFoundation
import AVKit
import Cocoa

/// Set PAGER_DEBUG to trace stacking on stderr. Both bugs that cost the most
/// time here were silent: a panel that never claimed a slot and a panel that
/// gave one up looked identical from the outside.
enum Debug {
    static let on = ProcessInfo.processInfo.environment["PAGER_DEBUG"] != nil
    static func log(_ message: @autoclosure () -> String) {
        guard on, let data = (message() + "\n").data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

// MARK: - theme

/// One place for every number. Sizes are multiplied by a scale derived from the
/// screen, so the panel keeps its apparent size across the Scaled display
/// settings instead of shrinking as the logical resolution grows.
struct Theme {
    let scale: CGFloat

    var pad: CGFloat            { 14 * scale }
    var radius: CGFloat         { 15 * scale }
    var rowGap: CGFloat         { 9 * scale }
    var inlineGap: CGFloat      { 6 * scale }
    var buttonRadius: CGFloat   { 7 * scale }
    var chipRadius: CGFloat     { 5 * scale }
    var iconSide: CGFloat       { 22 * scale }
    var progressHeight: CGFloat { 2 }

    func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: (size * scale).rounded(), weight: weight)
    }

    static let surfaceIdle = CGFloat(0.075)
    static let surfaceHover = CGFloat(0.16)
}

/// A small markdown subset for panel text: **bold**, *italic*, `code`, and a
/// backslash to escape any of them. Callers pass a string; nobody should have
/// to build an NSAttributedString to put one word in bold.
enum Markup {
    static func attributed(_ source: String, theme: Theme, size: CGFloat,
                           weight: NSFont.Weight, colour: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var buffer = ""
        var bold = false, italic = false, code = false
        var index = source.startIndex

        func emit() {
            guard !buffer.isEmpty else { return }
            var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: colour]
            if code {
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: (size * theme.scale * 0.93).rounded(), weight: .medium)
                attributes[.backgroundColor] = NSColor.white.withAlphaComponent(0.10)
            } else {
                let face = theme.font(size, bold ? .bold : weight)
                attributes[.font] = italic
                    ? NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask)
                    : face
            }
            result.append(NSAttributedString(string: buffer, attributes: attributes))
            buffer = ""
        }

        while index < source.endIndex {
            let character = source[index]
            if character == "\\", source.index(after: index) < source.endIndex {
                index = source.index(after: index)
                buffer.append(source[index])
                index = source.index(after: index)
                continue
            }
            if !code, source[index...].hasPrefix("**") {
                emit(); bold.toggle(); index = source.index(index, offsetBy: 2); continue
            }
            if !code, character == "*" {
                emit(); italic.toggle(); index = source.index(after: index); continue
            }
            if character == "`" {
                emit(); code.toggle(); index = source.index(after: index); continue
            }
            buffer.append(character)
            index = source.index(after: index)
        }
        emit()
        return result
    }
}

// MARK: - components

/// A flat button. AppKit draws the title, we own the background, so there is no
/// custom text drawing to get wrong.
final class Pill: NSButton {
    var theme: Theme!
    var tint: NSColor = .labelColor
    var idle = Theme.surfaceIdle
    var hover = Theme.surfaceHover
    var padH: CGFloat = 10
    var square = false
    private var hovering = false

    convenience init(title: String, symbol: String?, theme: Theme,
                     target: AnyObject, action: Selector, tint: NSColor = .labelColor) {
        self.init(frame: .zero)
        self.theme = theme
        self.tint = tint
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.bezelStyle = .regularSquare
        self.layer?.cornerRadius = theme.buttonRadius
        self.padH = 10 * theme.scale

        if let symbol {
            self.square = true
            let config = NSImage.SymbolConfiguration(pointSize: 11 * theme.scale, weight: .medium)
            self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
                .withSymbolConfiguration(config)
            self.imagePosition = .imageOnly
            self.contentTintColor = .secondaryLabelColor
            self.toolTip = title
        } else {
            self.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: theme.font(11.5, .medium),
                .foregroundColor: tint,
            ])
        }
        refresh()
    }

    override var intrinsicContentSize: NSSize {
        if square { return NSSize(width: theme.iconSide, height: theme.iconSide) }
        var size = super.intrinsicContentSize
        size.width += padH * 2
        size.height = 23 * theme.scale
        return size
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    /// `lit` is the pinned state: the button stays filled while the mode is on.
    var lit = false { didSet { refresh() } }
    var forcedFill: NSColor? { didSet { refresh() } }

    /// Lets a caller give one button its own identity, e.g. a GitHub button
    /// that looks like GitHub rather than like every other button.
    func decorate(icon: NSImage?, fill: NSColor?, label: NSColor?, theme: Theme) {
        if let icon {
            icon.size = NSSize(width: (13 * theme.scale).rounded(), height: (13 * theme.scale).rounded())
            self.image = icon
            self.imagePosition = .imageLeading
            self.imageHugsTitle = true
        }
        if let label {
            self.attributedTitle = NSAttributedString(string: attributedTitle.string, attributes: [
                .font: theme.font(11.5, .semibold), .foregroundColor: label,
            ])
        }
        forcedFill = fill
        refresh()
    }

    func refresh() {
        if let forcedFill {
            layer?.backgroundColor = (hovering
                ? forcedFill.blended(withFraction: 0.18, of: .white) ?? forcedFill
                : forcedFill).cgColor
            return
        }
        let alpha = lit ? 0.22 : (hovering ? hover : idle)
        let base = lit ? tint : NSColor.white
        layer?.backgroundColor = base.withAlphaComponent(alpha).cgColor
        if square { contentTintColor = lit ? tint : .secondaryLabelColor }
    }
}

/// A bare symbol. No border, no fill at rest: it is chrome only when you are
/// pointing at it. Buttons that are always visible should not look like buttons.
final class Glyph: NSButton {
    private var theme: Theme!
    private var hovering = false
    private var symbol = ""
    var tint: NSColor = .tertiaryLabelColor
    var lit = false { didSet { refresh() } }

    convenience init(symbol: String, tooltip: String, theme: Theme,
                     target: AnyObject, action: Selector, tint: NSColor = .tertiaryLabelColor) {
        self.init(frame: .zero)
        self.theme = theme
        self.tint = tint
        self.symbol = symbol
        self.target = target
        self.action = action
        self.isBordered = false
        self.wantsLayer = true
        self.bezelStyle = .regularSquare
        self.imagePosition = .imageOnly
        self.toolTip = tooltip
        self.layer?.cornerRadius = 5 * theme.scale
        set(symbol: symbol)
        refresh()
    }

    func set(symbol name: String) {
        symbol = name
        image = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)?
            .withSymbolConfiguration(.init(pointSize: 11 * theme.scale, weight: .semibold))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 20 * theme.scale, height: 20 * theme.scale)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    private func refresh() {
        contentTintColor = lit ? tint : (hovering ? .labelColor : .tertiaryLabelColor)
        layer?.backgroundColor = hovering
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
    }
}

/// The panel background. Exists so a middle click anywhere on the card can
/// dismiss it without hunting for the close control.
final class Surface: NSVisualEffectView {
    var onMiddleClick: (() -> Void)?
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onMiddleClick?() } else { super.otherMouseDown(with: event) }
    }
}

/// A small dim label. Used instead of joining metadata with separators,
/// which is what made the old meta row read as a run-on sentence.
final class Chip: NSView {
    init(_ text: String, theme: Theme, emphasis: Bool) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = emphasis ? theme.font(10.5, .semibold) : theme.font(10.5, .regular)
        label.textColor = emphasis ? .secondaryLabelColor : .tertiaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }
}

/// A minimal line chart, so a notification can carry a shape and not just words.
final class Sparkline: NSView {
    private let points: [Double]
    private let tint: NSColor

    init(points: [Double], tint: NSColor, theme: Theme) {
        self.points = points
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 34 * theme.scale).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let low = points.min() ?? 0, high = points.max() ?? 1
        let span = high - low == 0 ? 1 : high - low
        let step = bounds.width / CGFloat(points.count - 1)

        let line = NSBezierPath()
        var coordinates: [NSPoint] = []
        for (index, value) in points.enumerated() {
            let x = CGFloat(index) * step
            let y = bounds.minY + CGFloat((value - low) / span) * (bounds.height - 4) + 2
            coordinates.append(NSPoint(x: x, y: y))
        }
        line.move(to: coordinates[0])
        coordinates.dropFirst().forEach { line.line(to: $0) }

        guard let area = line.copy() as? NSBezierPath else { return }
        area.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        area.line(to: NSPoint(x: bounds.minX, y: bounds.minY))
        area.close()
        tint.withAlphaComponent(0.14).setFill()
        area.fill()

        tint.withAlphaComponent(0.9).setStroke()
        line.lineWidth = 1.5
        line.lineJoinStyle = .round
        line.stroke()

        if let last = coordinates.last {
            let dot = NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5))
            tint.setFill()
            dot.fill()
        }
    }
}

// MARK: - media

/// The shape of a sound plus how long it runs. Read in chunks so a long voice
/// message does not pull the whole file into memory to draw a few hundred bars.
struct Clip {
    var peaks: [CGFloat] = []
    var duration: Double = 0

    static func read(_ url: URL, buckets: Int = 320) -> Clip {
        guard buckets > 0, let file = try? AVAudioFile(forReading: url), file.length > 0 else { return Clip() }
        let format = file.processingFormat
        let seconds = Double(file.length) / format.sampleRate
        let per = max(1, Int(file.length) / buckets)
        let capacity = AVAudioFrameCount(min(max(per * 4, 8192), 1 << 18))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return Clip(peaks: [], duration: seconds)
        }

        var bars: [CGFloat] = []
        var peak: Float = 0
        var filled = 0
        while (try? file.read(into: buffer)) != nil, buffer.frameLength > 0 {
            guard let data = buffer.floatChannelData else { break }
            let frames = Int(buffer.frameLength)
            let channels = Int(format.channelCount)
            var index = 0
            while index < frames {
                let take = min(per - filled, frames - index)
                for channel in 0..<channels {
                    let samples = data[channel]
                    for offset in index..<(index + take) { peak = max(peak, abs(samples[offset])) }
                }
                filled += take
                index += take
                if filled >= per { bars.append(CGFloat(peak)); peak = 0; filled = 0 }
            }
        }
        if filled > 0 { bars.append(CGFloat(peak)) }
        let loudest = bars.max() ?? 0
        if loudest > 0 { bars = bars.map { $0 / loudest } }
        return Clip(peaks: bars, duration: seconds)
    }

    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// Bars for the clip, filled up to the play head. Click anywhere to seek.
final class WaveView: NSView {
    private let peaks: [CGFloat]
    private let tint: NSColor
    private let scale: CGFloat
    var onSeek: ((Double) -> Void)?
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }

    init(peaks: [CGFloat], tint: NSColor, scale: CGFloat) {
        self.peaks = peaks
        self.tint = tint
        self.scale = scale
        super.init(frame: .zero)
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: (17 * scale).rounded())
    }

    override func draw(_ dirty: NSRect) {
        guard !peaks.isEmpty, bounds.width > 1 else { return }
        let bar = max(1, (2 * scale).rounded())
        let step = bar + max(1, (1.5 * scale).rounded())
        let count = max(1, Int(bounds.width / step))
        let floorHeight = max(1, 1.5 * scale)
        for index in 0..<count {
            let lower = index * peaks.count / count
            let upper = max(lower + 1, (index + 1) * peaks.count / count)
            let value = peaks[lower..<min(upper, peaks.count)].max() ?? 0
            let height = max(floorHeight, value * (bounds.height - 2))
            let x = CGFloat(index) * step
            let played = (x + bar / 2) <= bounds.width * progress
            (played ? tint : NSColor.white.withAlphaComponent(0.20)).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: bounds.midY - height / 2, width: bar, height: height),
                         xRadius: bar / 2, yRadius: bar / 2).fill()
        }
    }

    // Handling the click here also stops it reaching the window, which would
    // otherwise start dragging the panel instead of seeking.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onSeek?(Double(max(0, min(1, point.x / max(1, bounds.width)))))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// One playable line: a play control, a name, the waveform, its length, and
/// whatever the caller wants on the right of it.
final class AudioRow: NSStackView {
    let name: String
    let url: URL
    private let wave: WaveView
    private let toggle: Glyph

    init(name: String, url: URL, clip: Clip, nameWidth: CGFloat,
         theme: Theme, tint: NSColor, trailing: NSView?) {
        self.name = name
        self.url = url
        self.wave = WaveView(peaks: clip.peaks, tint: tint, scale: theme.scale)
        self.toggle = Glyph(symbol: "play.fill", tooltip: "Play", theme: theme,
                            target: Playback.shared, action: #selector(Playback.toggleSender(_:)))
        super.init(frame: .zero)

        toggle.identifier = NSUserInterfaceItemIdentifier(name)

        let label = NSTextField(labelWithString: name)
        label.font = theme.font(11.5, .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: nameWidth).isActive = true

        let length = NSTextField(labelWithString: Clip.clock(clip.duration))
        length.font = theme.font(10, .regular)
        length.textColor = .tertiaryLabelColor
        length.alignment = .right
        length.translatesAutoresizingMaskIntoConstraints = false
        length.widthAnchor.constraint(equalToConstant: (30 * theme.scale).rounded()).isActive = true

        wave.onSeek = { [weak self] fraction in
            guard let self else { return }
            Playback.shared.seek(self, to: fraction)
        }

        var views: [NSView] = [toggle, label, wave, length]
        if let trailing { views.append(trailing) }
        setViews(views, in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = theme.inlineGap
    }

    required init?(coder: NSCoder) { nil }

    func show(playing: Bool) {
        toggle.set(symbol: playing ? "pause.fill" : "play.fill")
        toggle.lit = playing
    }

    func show(progress: Double) { wave.progress = CGFloat(progress) }
}

/// One sound at a time, across every row on the panel. Owning playback here
/// rather than in the rows is what makes starting one stop the others.
final class Playback: NSObject, AVAudioPlayerDelegate {
    static let shared = Playback()
    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private weak var owner: AudioRow?
    /// Raised while anything is sounding, so the panel can hold its countdown.
    var onChange: ((Bool) -> Void)?

    @objc func toggleSender(_ sender: NSButton) {
        guard let row = sender.superview as? AudioRow else { return }
        toggle(row)
    }

    func toggle(_ row: AudioRow) {
        if owner === row, let player {
            if player.isPlaying { player.pause(); tick(false) } else { player.play(); tick(true) }
            row.show(playing: player.isPlaying)
            return
        }
        start(row, at: 0)
    }

    func seek(_ row: AudioRow, to fraction: Double) {
        if owner === row, let player {
            player.currentTime = player.duration * fraction
            row.show(progress: fraction)
            if !player.isPlaying { player.play(); tick(true); row.show(playing: true) }
            return
        }
        start(row, at: fraction)
    }

    private func start(_ row: AudioRow, at fraction: Double) {
        stop()
        guard let made = try? AVAudioPlayer(contentsOf: row.url) else { return }
        made.delegate = self
        made.currentTime = made.duration * fraction
        player = made
        owner = row
        made.play()
        row.show(playing: true)
        row.show(progress: fraction)
        tick(true)
    }

    func stop() {
        player?.stop()
        player = nil
        owner?.show(playing: false)
        owner?.show(progress: 0)
        owner = nil
        tick(false)
    }

    private func tick(_ on: Bool) {
        ticker?.invalidate()
        ticker = nil
        if on {
            ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self, let player = self.player else { return }
                self.owner?.show(progress: player.duration > 0 ? player.currentTime / player.duration : 0)
            }
        }
        onChange?(on)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stop() }
}

// MARK: - options

struct Action {
    let label: String
    let command: String
}

struct Options {
    var title = ""
    var body = ""
    var source = ""
    var app = ""
    var icon = ""
    var subtitle = ""
    var chips: [String] = []
    var actions: [Action] = []
    var actionIcon: [Int: String] = [:]
    var actionFill: [Int: NSColor] = [:]
    var actionText: [Int: NSColor] = [:]
    var copies: [Action] = []
    var sparkline: [Double] = []
    var audio: [Action] = []
    var choose: Action?
    var image = ""
    var video = ""
    var mediaHeight: CGFloat = 0
    var width: CGFloat = 0
    var seconds: Double = 180
    var accent = NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.0, alpha: 1.0)
    var compact = false
    var pinned = false
    var sound = ""
    var stack = Slots.Mode.vertical
    var offset = CGPoint.zero
    var corner: Slots.Corner?
    var display: Int?
    var loop = false
    var gap: CGFloat = 12

    static func colour(_ hex: String) -> NSColor? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        return NSColor(calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
                       green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            let next: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch flag {
            case "--title":     options.title = next ?? ""; index += 1
            case "--body":      options.body = next ?? ""; index += 1
            case "--source":    options.source = next ?? ""; index += 1
            case "--app":       options.app = next ?? ""; index += 1
            case "--icon":      options.icon = next ?? ""; index += 1
            case "--subtitle":  options.subtitle = next ?? ""; index += 1
            case "--chip", "--meta": if let n = next { options.chips.append(n) }; index += 1
            // A zero or negative value would close the panel before anyone
            // could see it, which is never what a caller meant to ask for.
            case "--seconds":   options.seconds = max(2, Double(next ?? "") ?? 180); index += 1
            case "--accent":    if let n = next, let c = colour(n) { options.accent = c }; index += 1
            case "--sparkline":
                options.sparkline = (next ?? "").split(whereSeparator: { ",; ".contains($0) })
                    .compactMap { Double($0) }
                index += 1
            // These decorate the action they follow, so one button can carry a
            // brand without inventing a syntax inside --action.
            case "--action-icon":
                if let n = next, let last = options.actions.indices.last { options.actionIcon[last] = n }
                index += 1
            case "--action-fill":
                if let n = next, let c = colour(n), let last = options.actions.indices.last { options.actionFill[last] = c }
                index += 1
            case "--action-text":
                if let n = next, let c = colour(n), let last = options.actions.indices.last { options.actionText[last] = c }
                index += 1
            case "--image":     options.image = next ?? ""; index += 1
            case "--video":     options.video = next ?? ""; index += 1
            case "--media-height": options.mediaHeight = CGFloat(Double(next ?? "") ?? 0); index += 1
            case "--width":     options.width = CGFloat(Double(next ?? "") ?? 0); index += 1
            case "--stack":     options.stack = Slots.Mode(rawValue: next ?? "") ?? .vertical; index += 1
            case "--corner":    options.corner = Slots.Corner(rawValue: next ?? ""); index += 1
            case "--display":   options.display = Int(next ?? ""); index += 1
            case "--loop":      options.loop = true
            case "--gap":       options.gap = CGFloat(Double(next ?? "") ?? 12); index += 1
            case "--offset":
                let parts = (next ?? "").split(whereSeparator: { ",; ".contains($0) }).compactMap { Double($0) }
                if parts.count == 2 { options.offset = CGPoint(x: parts[0], y: parts[1]) }
                index += 1
            case "--sound":     options.sound = next ?? ""; index += 1
            case "--compact":   options.compact = true
            case "--pinned":    options.pinned = true
            case "--action", "--copy", "--audio", "--choose":
                if let n = next, let split = n.firstIndex(of: ":") {
                    let item = Action(label: String(n[n.startIndex..<split]),
                                      command: String(n[n.index(after: split)...]))
                    switch flag {
                    case "--copy":   options.copies.append(item)
                    case "--audio":  options.audio.append(item)
                    case "--choose": options.choose = item
                    default:         options.actions.append(item)
                    }
                }
                index += 1
            default: break
            }
            index += 1
        }
        return options
    }
}

// MARK: - stacking

/// Panels stack from an anchor corner with no gaps, because each records the
/// height it actually occupies rather than everyone assuming a shared size. A
/// slot file holds "pid height", so a panel that is killed rather than closed
/// cannot leak its position: the next one checks whether that pid still exists.
enum Slots {
    static let directory = ("~/.pager" as NSString).expandingTildeInPath
    static let anchorFile = directory + "/anchor"

    /// Which corner a panel belongs to. Each corner stacks independently, so
    /// two groups of panels can sit side by side without knowing each other's
    /// widths. Positioning by corner is reliable in a way an offset in points
    /// never is, because every panel right-aligns to its own width.
    enum Corner: String {
        case bottomRight = "bottom-right", bottomLeft = "bottom-left"
        case topRight = "top-right", topLeft = "top-left"

        var isTop: Bool { self == .topRight || self == .topLeft }
        var isLeft: Bool { self == .bottomLeft || self == .topLeft }

        func origin(in visible: NSRect, width: CGFloat, height: CGFloat, margin: CGFloat) -> NSPoint {
            NSPoint(x: isLeft ? visible.minX + margin : visible.maxX - width - margin,
                    y: isTop ? visible.maxY - height - margin : visible.minY + margin)
        }
    }

    enum Mode: String, Equatable {
        case vertical, cascade, none

        /// Where the nth live panel goes, given the space already taken. Panels
        /// grow away from their corner, so a top corner stacks downward.
        func offset(index: Int, stackedHeight: CGFloat, gap: CGFloat,
                    scale: CGFloat, corner: Corner) -> NSPoint {
            let dy: CGFloat = corner.isTop ? -1 : 1
            let dx: CGFloat = corner.isLeft ? 1 : -1
            switch self {
            case .vertical: return NSPoint(x: 0, y: dy * (stackedHeight + gap * CGFloat(index)))
            // The step has to clear the identity row and the title beneath it,
            // or the panel in front hides the very thing that says what the one
            // behind is. Newest is drawn on top, so at a top corner this reveals
            // each title going back; at a bottom corner it reveals each footer.
            case .cascade:  return NSPoint(x: dx * 20 * scale * CGFloat(index),
                                           y: dy * 62 * scale * CGFloat(index))
            case .none:     return .zero
            }
        }
    }

    /// kill(pid, 0) succeeds for a zombie, so a panel killed by a parent that
    /// never reaps it would hold its slot and leave a hole in the stack. Ask
    /// the kernel what state the process is actually in.
    private static func alive(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return kill(pid, 0) == 0 && errno == EPERM
        }
        return info.kp_proc.p_stat != SZOMB
    }

    private static func occupant(_ path: String) -> CGFloat? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // Split on whitespace, not on spaces. The line ends in a newline, and
        // Double("68\n") is nil, which silently made every neighbour's height
        // read as zero and stacked every panel on top of the last one.
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let pid = pid_t(parts.first ?? ""), alive(pid) else { return nil }
        return CGFloat(parts.count > 1 ? Double(parts[1]) ?? 0 : 0)
    }

    /// Claiming is done under an exclusive lock. Without it, two panels
    /// launched together can both see a slot file that exists but has not been
    /// written yet, both judge it stale, and both take the same position.
    /// What sits below a slot right now: how much height, and how many panels.
    /// Recomputing this is what lets a panel notice that something under it
    /// closed and slide down into the space.
    static func occupancy(below slot: Int, corner: Corner) -> (height: CGFloat, count: Int) {
        var height: CGFloat = 0
        var count = 0
        for other in 0..<slot {
            if let taken = occupant("\(directory)/slot-\(corner.rawValue)-\(other)") {
                height += taken
                count += 1
            }
        }
        return (height, count)
    }

    static func claim(height: CGFloat, gap: CGFloat, mode: Mode, scale: CGFloat, corner: Corner)
        -> (marker: String, offset: NSPoint, slot: Int) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let lock = open(directory + "/.claim.lock", O_CREAT | O_RDWR, 0o644)
        if lock >= 0 { flock(lock, LOCK_EX) }
        defer { if lock >= 0 { flock(lock, LOCK_UN); close(lock) } }

        var stacked: CGFloat = 0
        var index = 0
        for slot in 0..<12 {
            let marker = "\(directory)/slot-\(corner.rawValue)-\(slot)"
            if let taken = occupant(marker) {
                stacked += taken
                index += 1
                continue
            }
            try? FileManager.default.removeItem(atPath: marker)
            let fd = open(marker, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd < 0 { continue }
            var line = "\(getpid()) \(Int(height))\n"
            line.withUTF8 { _ = write(fd, $0.baseAddress, $0.count) }
            close(fd)
            Debug.log("claimed slot-\(slot) index=\(index) stacked=\(stacked) height=\(height)")
            return (marker, mode.offset(index: index, stackedHeight: stacked, gap: gap,
                                        scale: scale, corner: corner), slot)
        }
        return ("\(directory)/slot-\(corner.rawValue)-0", .zero, 0)
    }

    static func anchor() -> NSPoint? {
        guard let text = try? String(contentsOfFile: anchorFile, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ").compactMap { Double($0) }
        return parts.count == 2 ? NSPoint(x: parts[0], y: parts[1]) : nil
    }

    static func remember(anchor point: NSPoint) {
        try? "\(Int(point.x)) \(Int(point.y))\n"
            .write(toFile: anchorFile, atomically: true, encoding: .utf8)
    }
}

/// One line per raised panel. Not for anything to read back and imitate, but so
/// you can answer "what paged me today, and what is paging me too often".
/// The log. Every panel writes a small stream of events: what was shown, which
/// command asked for it, and how it ended. One JSON object per line so it can
/// be tailed, grepped and read back without a parser.
///
/// Knowing that a panel appeared is not worth much. Knowing that `backup.sh`
/// asked for it, that it sat there for four minutes, and that nobody answered,
/// is the thing you actually want at three in the morning.
enum Log {
    static var path: String { Slots.directory + "/log.jsonl" }
    static var previous: String { path + ".1" }
    private static let rotateBytes = 4 * 1024 * 1024

    /// The panel this process is, so its events can be stitched back together.
    static let panel = String(format: "%06x", getpid() & 0xffffff)

    /// The command that asked for this panel, read from the parent process.
    static let caller: String = name(of: getppid()) ?? "unknown"

    static func name(of pid: pid_t) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let text = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: Array(bytes) + [0])
        }
        return text.isEmpty ? nil : text
    }

    static func escape(_ text: String) -> String {
        var out = ""
        for character in text.unicodeScalars {
            switch character {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r", "\t": out += " "
            default:
                if character.value < 0x20 { out += " " } else { out.unicodeScalars.append(character) }
            }
        }
        return out
    }

    private static func field(_ key: String, _ value: Any) -> String? {
        switch value {
        case let text as String:
            return text.isEmpty ? nil : "\"\(key)\":\"\(escape(text))\""
        case let flag as Bool:
            return flag ? "\"\(key)\":true" : nil
        case let number as Int:
            return "\"\(key)\":\(number)"
        case let number as Double:
            return "\"\(key)\":\(String(format: "%.2f", number))"
        default:
            return nil
        }
    }

    /// Ids are monotonic so one event can point at another. The last one is read
    /// back from the tail rather than held in memory, because every panel is its
    /// own process and they all write to the same file.
    private static func nextID() -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else { return 1 }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size > 8192 ? size - 8192 : 0)
        guard let text = String(data: handle.readDataToEndOfFile(), encoding: .utf8) else { return 1 }
        for line in text.split(separator: "\n").reversed() {
            guard let mark = line.range(of: "\"id\":") else { continue }
            let digits = line[mark.upperBound...].prefix { $0.isNumber }
            if let value = Int(digits) { return value + 1 }
        }
        return 1
    }

    @discardableResult
    static func write(_ event: String, level: String = "info",
                      _ extra: [(String, Any)] = []) -> Int {
        try? FileManager.default.createDirectory(atPath: Slots.directory,
                                                 withIntermediateDirectories: true)
        rotate()
        let id = nextID()
        var parts = [
            "\"id\":\(id)",
            "\"at\":\"\(ISO8601DateFormatter().string(from: Date()))\"",
            "\"event\":\"\(escape(event))\"",
            "\"level\":\"\(level)\"",
            "\"panel\":\"\(panel)\"",
        ]
        parts += extra.compactMap { field($0.0, $0.1) }
        let line = "{" + parts.joined(separator: ",") + "}\n"

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return id
    }

    /// Roll over rather than truncate, so yesterday's history survives one more
    /// file instead of being thrown away mid-investigation.
    private static func rotate() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > rotateBytes else { return }
        try? FileManager.default.removeItem(atPath: previous)
        try? FileManager.default.moveItem(atPath: path, toPath: previous)
    }

    /// What a panel was, written once when it appears.
    static func shown(_ options: Options) {
        write("shown", level: options.pinned ? "warn" : "info", [
            ("app", options.app),
            ("source", options.source),
            ("title", options.title),
            ("caller", caller),
            ("cwd", FileManager.default.currentDirectoryPath),
            ("actions", options.actions.count),
            ("seconds", Int(options.seconds)),
            ("pinned", options.pinned),
            ("sound", options.sound),
            ("corner", (options.corner ?? .bottomRight).rawValue),
            ("media", options.video.isEmpty ? (options.image.isEmpty ? "" : "image") : "video"),
            ("audio", options.audio.count),
        ])
    }
}


/// Bundled sounds live next to the binary. A name resolves against
/// ~/.pager/sounds first so you can replace one without touching the repo, and
/// anything with a slash in it is taken as a path.
enum Paths {
    /// The checkout this binary was built from, found by walking up from argv[0]
    /// through the PATH symlink. Sounds, the tour and the skill all live there.
    static var repo: URL {
        URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()      // bin
            .deletingLastPathComponent()      // repo
    }
}

enum Sound {
    static var playing: NSSound?

    static var bundled: URL { Paths.repo.appendingPathComponent("sounds") }

    static func url(_ name: String) -> URL? {
        if name.isEmpty || name == "none" { return nil }
        if name.contains("/") {
            return URL(fileURLWithPath: (name as NSString).expandingTildeInPath)
        }
        let override = URL(fileURLWithPath: Slots.directory)
            .appendingPathComponent("sounds/\(name).wav")
        if FileManager.default.fileExists(atPath: override.path) { return override }
        return bundled.appendingPathComponent("\(name).wav")
    }

    static func play(_ name: String) {
        guard let url = url(name), FileManager.default.fileExists(atPath: url.path) else { return }
        playing = NSSound(contentsOf: url, byReference: false)
        playing?.play()
    }

    static var names: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: bundled.path))?
            .filter { $0.hasSuffix(".wav") }
            .map { String($0.dropLast(4)) }
            .sorted() ?? []
    }
}

// MARK: - reading the log

/// The log browser, in a terminal. Same shape as the one in Ouroboros: an id
/// gutter, the time, a level glyph, the event, where it came from, then the
/// message. Columns are ruled so the eye can drop down one of them.
enum LogView {
    static let lime = "\u{1B}[38;5;190m"
    static let dim = "\u{1B}[2m"
    static let faint = "\u{1B}[38;5;240m"
    static let off = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"

    static func tint(_ level: String) -> String {
        switch level {
        case "debug": return "\u{1B}[38;5;244m"
        case "warn":  return "\u{1B}[38;5;214m"
        case "error": return "\u{1B}[38;5;203m"
        default:      return "\u{1B}[38;5;75m"
        }
    }

    static func glyph(_ level: String) -> String {
        switch level {
        case "debug": return "\u{B7}"
        case "warn":  return "!"
        case "error": return "\u{2717}"
        default:      return "\u{25CF}"
        }
    }

    /// Enough of a JSON reader for lines this program wrote itself.
    static func parse(_ line: String) -> [String: String]? {
        guard line.hasPrefix("{") else { return nil }
        var out: [String: String] = [:]
        var key = "", value = "", inKey = false, inValue = false, quoted = false, escaped = false
        var unicode = ""                    // collecting the four digits of a \uXXXX
        var pending: UInt32?                // a high surrogate waiting for its partner

        func put(_ text: String) {
            if inKey { key += text } else if inValue { value += text }
        }
        func emit(_ code: UInt32) {
            // Emoji arrive as a surrogate pair, which has to be rejoined before
            // it is a character at all.
            if code >= 0xD800, code <= 0xDBFF { pending = code; return }
            var scalar = code
            if let high = pending, code >= 0xDC00, code <= 0xDFFF {
                scalar = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
            }
            pending = nil
            if let value = Unicode.Scalar(scalar) { put(String(Character(value))) }
        }

        for character in line.dropFirst() {
            if !unicode.isEmpty || (escaped && character == "u") {
                if escaped { escaped = false; unicode = "u"; continue }
                unicode.append(character)
                if unicode.count == 5 {
                    if let code = UInt32(unicode.dropFirst(), radix: 16) { emit(code) }
                    unicode = ""
                }
                continue
            }
            if escaped {
                switch character {
                case "n", "t", "r": put(" ")
                default: put(String(character))
                }
                escaped = false
                continue
            }
            if character == "\\" { escaped = true; continue }
            if character == "\"" {
                quoted.toggle()
                if quoted && !inValue && !inKey { inKey = true }
                else if !quoted && inKey { inKey = false }
                else if quoted && inValue { }
                else if !quoted && inValue { out[key] = value; key = ""; value = ""; inValue = false }
                continue
            }
            if !quoted && character == ":" { inValue = true; value = ""; continue }
            if !quoted && (character == "," || character == "}") {
                if inValue && !value.isEmpty { out[key] = value.trimmingCharacters(in: .whitespaces); key = ""; value = "" }
                inValue = false; continue
            }
            put(String(character))
        }
        return out.isEmpty ? nil : out
    }

    static func lines(_ limit: Int) -> [[String: String]] {
        var rows: [[String: String]] = []
        for file in [Log.previous, Log.path] {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            rows += text.split(separator: "\n").compactMap { parse(String($0)) }
        }
        // Lines written before the log carried events were all one thing: a
        // panel appearing. Name them so old history reads like the new.
        return Array(rows.suffix(limit)).map { row -> [String: String] in
            var row = row
            if row["event"] == nil { row["event"] = "shown"; row["level"] = "info"; row["legacy"] = "yes" }
            return row
        }
    }

    static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count > width ? String(text.prefix(width - 1)) + "\u{2026}" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    static func clock(_ stamp: String) -> String {
        let time = stamp.split(separator: "T").last.map { String($0.prefix(8)) } ?? stamp
        return time
    }

    static func row(_ event: [String: String]) -> String {
        let level = event["level"] ?? "info"
        let colour = tint(level)
        let rule = "\(faint)\u{2502}\(off)"
        let source = event["source"] ?? event["app"] ?? ""
        var message = event["title"] ?? ""
        if let answer = event["answer"], !answer.isEmpty { message = "\(answer)  \(dim)\(message)\(off)" }
        if let choice = event["choice"] { message = "\(choice)  \(dim)\(message)\(off)" }
        if let caller = event["caller"], event["event"] == "shown" {
            message += "  \(faint)\u{2190} \(caller)\(off)"
        }
        if let alive = event["alive"], event["event"] != "shown" {
            message += "  \(faint)\(alive)s\(off)"
        }
        return "  \(faint)\(pad(event["id"] ?? "", 5))\(off) \(rule) "
            + "\(dim)\(clock(event["at"] ?? ""))\(off) \(rule) "
            + "\(colour)\(glyph(level))\(off) \(rule) "
            + "\(colour)\(pad(event["event"] ?? "", 9))\(off) \(rule) "
            + "\(dim)\(pad(source, 12))\(off) \(rule) "
            + message
    }

    /// A terminal gets the ruled, coloured view. Anything else gets the lines
    /// exactly as they were written. Nobody should have to parse a table back
    /// into data that was already JSON on disk.
    static var isTerminal: Bool { isatty(fileno(stdout)) == 1 }

    static func show(_ arguments: [String]) {
        var limit = 40, follow = false, filters: [String: String] = [:], search = ""
        var raw = !isTerminal
        var index = 0
        var wantsWindow = false
        while index < arguments.count {
            let flag = arguments[index]
            let next = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch flag {
            case "-n", "--lines":  limit = Int(next) ?? 40; index += 1
            case "-f", "--follow": follow = true
            case "--source", "--app", "--event", "--caller", "--level":
                filters[String(flag.dropFirst(2))] = next; index += 1
            case "--errors":       filters["level"] = "error"
            case "--grep":         search = next; index += 1
            case "--json":         raw = true
            case "--pretty":       raw = false
            case "--window", "--open": wantsWindow = true
            case "--stats":        stats(); return
            case "--path":         print(Log.path); return
            default: break
            }
            index += 1
        }

        if wantsWindow {
            let ranks = ["debug": 0, "info": 1, "warn": 2, "error": 3]
            openWindow(search: search.isEmpty ? (filters["source"] ?? filters["caller"] ?? "") : search,
                       level: ranks[filters["level"] ?? ""] ?? 0)
            return
        }

        func keep(_ event: [String: String]) -> Bool {
            for (key, want) in filters {
                let have = event[key] ?? (key == "source" ? (event["app"] ?? "") : "")
                if !have.lowercased().contains(want.lowercased()) { return false }
            }
            if !search.isEmpty {
                let hay = event.values.joined(separator: " ").lowercased()
                if !hay.contains(search.lowercased()) { return false }
            }
            return true
        }

        let rows = lines(20_000).filter(keep).suffix(limit)

        if raw {
            for event in rows { print(json(event)) }
            if follow { followRaw(rows.last, keep) }
            return
        }

        print("")
        print("  \(lime)\(bold)pager log\(off)  \(dim)\(rows.count) of \(lines(20_000).count) events\(off)")
        print("  \(faint)\(String(repeating: "\u{2500}", count: 74))\(off)")
        for event in rows { print(row(event)) }
        print("")

        guard follow else { return }
        var seen = rows.last?["id"].flatMap { Int($0) } ?? 0
        while true {
            Thread.sleep(forTimeInterval: 0.7)
            for event in lines(400) where (Int(event["id"] ?? "") ?? 0) > seen {
                guard keep(event) else { continue }
                print(row(event))
                seen = Int(event["id"] ?? "") ?? seen
            }
        }
    }

    /// Written back out as one object per line, the way it went in.
    static func json(_ event: [String: String]) -> String {
        let numeric: Set<String> = ["id", "actions", "seconds", "audio", "alive", "for"]
        let order = ["id", "at", "event", "level", "panel", "app", "source", "title",
                     "caller", "cwd", "answer", "choice", "via", "alive", "for",
                     "actions", "seconds", "pinned", "sound", "corner", "media", "audio"]
        var parts: [String] = []
        for key in order + event.keys.sorted().filter({ !order.contains($0) }) {
            guard let value = event[key], key != "legacy" else { continue }
            if numeric.contains(key) || value == "true" || value == "false" {
                parts.append("\"\(key)\":\(value)")
            } else {
                parts.append("\"\(key)\":\"\(Log.escape(value))\"")
            }
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private static func followRaw(_ last: [String: String]?, _ keep: ([String: String]) -> Bool) {
        var seen = last?["id"].flatMap { Int($0) } ?? 0
        while true {
            Thread.sleep(forTimeInterval: 0.7)
            for event in lines(400) where (Int(event["id"] ?? "") ?? 0) > seen {
                if keep(event) { print(json(event)); fflush(stdout) }
                seen = Int(event["id"] ?? "") ?? seen
            }
        }
    }

    /// The same log, as a window, for reading rather than grepping.
    static func openWindow(search: String = "", level: Int = 0) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Panels run as an accessory and never reach the Dock. The log window
        // does, so it is the one thing that needs a face.
        if let icon = NSImage(contentsOfFile: Paths.repo.appendingPathComponent("assets/icon.png").path) {
            app.applicationIconImage = icon
        }
        let browser = LogWindow()
        browser.start(search: search, level: level)
        window = browser
        app.run()
    }

    private static var window: LogWindow?

    static func stats() {
        let rows = lines(50_000)
        let shown = rows.filter { $0["event"] == "shown" }
        var byCaller: [String: Int] = [:], bySource: [String: Int] = [:], byEnd: [String: Int] = [:]
        for event in shown {
            let caller = event["caller"] ?? ""
            byCaller[caller.isEmpty ? "unrecorded" : caller, default: 0] += 1
            let from = [event["source"], event["app"]].compactMap { $0 }.first { !$0.isEmpty }
            bySource[from ?? "-", default: 0] += 1
        }
        for event in rows where ["answered", "dismissed", "expired", "snoozed"].contains(event["event"] ?? "") {
            byEnd[event["event"]!, default: 0] += 1
        }
        let answered = byEnd["answered"] ?? 0
        let ended = byEnd.values.reduce(0, +)

        print("")
        print("  \(lime)\(bold)pager stats\(off)  \(dim)\(shown.count) panels, \(rows.count) events\(off)")
        print("  \(faint)\(String(repeating: "\u{2500}", count: 60))\(off)")
        func table(_ title: String, _ counts: [String: Int]) {
            guard !counts.isEmpty else { return }
            print("\n  \(dim)\(title)\(off)")
            for (name, count) in counts.sorted(by: { $0.value > $1.value }).prefix(8) {
                let bar = String(repeating: "\u{2588}", count: max(1, count * 22 / max(1, counts.values.max()!)))
                print("  \(pad(name, 18)) \(lime)\(bar)\(off) \(dim)\(count)\(off)")
            }
        }
        table("what calls pager", byCaller)
        table("by source", bySource)
        table("how they end", byEnd)
        if ended > 0 {
            print("\n  \(dim)answered\(off) \(lime)\(answered * 100 / ended)%\(off) \(dim)of the panels that closed\(off)")
        }
        print("")
    }
}

// MARK: - the log window

/// The log, as a window. Same bones as the browser in Ouroboros: an id gutter,
/// the time, a level glyph, the event, where it came from, then the message,
/// ruled into columns, with a row opening to show everything it carries.
/// Dressed in pager's own materials rather than the system's.
final class LogWindow: NSObject, NSTableViewDelegate, NSTableViewDataSource {
    private struct Col {
        static let gutter: CGFloat = 52
        static let time: CGFloat = 70
        static let level: CGFloat = 24
        static let event: CGFloat = 92
        static let source: CGFloat = 118
    }

    private let theme = Theme(scale: 1)
    private var window: NSWindow!
    private var table: NSTableView!
    private var footer: NSTextField!
    private var search = ""
    private var level = 0                      // 0 all · 1 info · 2 warn · 3 error
    private var rows: [[String: String]] = []
    private var expanded = Set<String>()
    private var timer: Timer?

    static let lime = NSColor(calibratedRed: 0.78, green: 1.0, blue: 0.0, alpha: 1)
    static let ink = NSColor(calibratedRed: 0.055, green: 0.063, blue: 0.075, alpha: 1)

    private static func hex(_ value: Int) -> NSColor {
        NSColor(calibratedRed: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    /// The same colours the panels themselves use.
    private func tint(_ level: String) -> NSColor {
        switch level {
        case "debug": return NSColor.tertiaryLabelColor
        case "warn":  return LogWindow.hex(0xffb300)
        case "error": return LogWindow.hex(0xff5f57)
        default:      return LogWindow.hex(0x5ac8fa)
        }
    }

    /// "2026-08-20" reads as "Thu 20 Aug 2026" on the divider.
    private func readable(_ day: String) -> String {
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        let out = DateFormatter()
        out.dateFormat = Calendar.current.isDateInToday(date) ? "'today'  ·  EEE d MMM yyyy"
            : (Calendar.current.isDateInYesterday(date) ? "'yesterday'  ·  EEE d MMM yyyy"
                                                        : "EEE d MMM yyyy")
        return out.string(from: date).uppercased()
    }

    private func glyph(_ level: String) -> String {
        switch level {
        case "debug": return "·"
        case "warn":  return "!"
        case "error": return "✗"
        default:      return "●"
        }
    }

    /// Opening already filtered, so `pager log --window --grep deploy` lands on
    /// the thing you went looking for.
    func start(search: String, level: Int) {
        self.search = search
        self.level = level
        open()
    }

    func open() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = NSSize(width: min(1020, screen.width - 80), height: min(660, screen.height - 80))
        window = NSWindow(contentRect: NSRect(x: screen.midX - size.width / 2,
                                              y: screen.midY - size.height / 2,
                                              width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "pager log"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 360)
        // Dark on its own terms. A log you read for ten minutes should not
        // change colour with whatever happens to be behind it.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = LogWindow.ink

        let blur = NSVisualEffectView()
        blur.material = .underPageBackground
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.backgroundColor = LogWindow.ink.cgColor
        window.contentView = blur

        let toolbar = buildToolbar()
        let header = buildHeader()

        table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 22
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("line")))
        table.target = self
        table.action = #selector(clicked)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false

        footer = label("", 10, .regular, .tertiaryLabelColor, mono: true)

        let footerBar = NSView()
        footerBar.wantsLayer = true
        footerBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.03).cgColor
        footer.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 14),
            footer.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 26),
        ])

        let column = NSStackView(views: [toolbar, rule(), header, rule(), scroll, rule(), footerBar])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            column.topAnchor.constraint(equalTo: blur.topAnchor, constant: 28),
            column.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        for view in [toolbar, header, scroll, footerBar] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }

        reload()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // The log is written by other processes, so watch it rather than assume.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reload(keepScroll: true)
        }
    }

    private func vrule() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.widthAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func rule() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight,
                       _ colour: NSColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        field.textColor = colour
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func buildToolbar() -> NSView {
        let bar = NSView()

        let title = label("pager log", 13, .semibold, LogWindow.lime)
        let dot = label("·", 13, .regular, .tertiaryLabelColor)
        let where_ = label(Log.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                           10.5, .regular, .tertiaryLabelColor, mono: true)

        let levels = NSSegmentedControl(labels: ["all", "info", "warn", "errors"],
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(levelChanged(_:)))
        levels.selectedSegment = level
        levels.segmentStyle = .rounded
        levels.controlSize = .small
        levels.font = .systemFont(ofSize: 11)
        levels.selectedSegmentBezelColor = LogWindow.lime.withAlphaComponent(0.85)

        let field = NSSearchField()
        field.placeholderString = "filter"
        field.font = .systemFont(ofSize: 11.5)
        field.controlSize = .small
        field.target = self
        field.action = #selector(searchChanged(_:))
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = true
        field.stringValue = search
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let left = NSStackView(views: [title, dot, where_])
        left.orientation = .horizontal
        left.spacing = 7
        left.alignment = .firstBaseline

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let row = NSStackView(views: [left, spacer, levels, field])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -10),
        ])
        return bar
    }

    private func buildHeader() -> NSView {
        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor

        func cell(_ text: String, _ width: CGFloat?) -> NSView {
            let field = label(text, 9, .semibold, LogWindow.lime.withAlphaComponent(0.5), mono: true)
            field.translatesAutoresizingMaskIntoConstraints = false
            if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
            return field
        }
        let cells = NSStackView(views: [
            cell("##", Col.gutter), vrule(), cell("TIME", Col.time), vrule(),
            cell("", Col.level), vrule(), cell("EVENT", Col.event), vrule(),
            cell("SOURCE", Col.source), vrule(), cell("MESSAGE", nil),
        ])
        cells.orientation = .horizontal
        cells.spacing = 8
        cells.alignment = .centerY
        cells.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(cells)
        NSLayoutConstraint.activate([
            cells.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            cells.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -14),
            cells.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 21),
        ])
        return bar
    }

    // MARK: data

    private func matches(_ event: [String: String]) -> Bool {
        let ranks = ["debug": 0, "info": 1, "warn": 2, "error": 3]
        if level > 0, (ranks[event["level"] ?? "info"] ?? 1) < level { return false }
        if !search.isEmpty {
            let hay = event.values.joined(separator: " ").lowercased()
            if !hay.contains(search.lowercased()) { return false }
        }
        return true
    }

    /// A time on its own is ambiguous once you scroll past midnight, so the
    /// day is announced as its own line rather than repeated on every row.
    private func withDays(_ events: [[String: String]]) -> [[String: String]] {
        var out: [[String: String]] = []
        var day = ""
        for event in events {
            let stamp = String((event["at"] ?? "").prefix(10))
            if stamp != day, !stamp.isEmpty {
                day = stamp
                out.append(["divider": stamp])
            }
            out.append(event)
        }
        return out
    }

    private func reload(keepScroll: Bool = false) {
        let all = LogView.lines(20_000)
        let filtered = withDays(all.filter(matches))
        guard !keepScroll || filtered.count != rows.count || rows.isEmpty else { return }
        let atBottom = keepScroll && isNearBottom()
        rows = filtered
        table.reloadData()
        if !keepScroll || atBottom { scrollToBottom() }

        let real = rows.filter { $0["divider"] == nil }
        let warn = real.filter { $0["level"] == "warn" }.count
        let errors = real.filter { $0["level"] == "error" }.count
        var text = "\(real.count) lines"
        if real.count != all.count { text += " of \(all.count)" }
        if let first = real.first?["at"], let last = real.last?["at"] {
            text += "   ·   \(first.prefix(10))  →  \(last.prefix(10))"
        }
        if warn > 0 { text += "   ·   \(warn) warn" }
        if errors > 0 { text += "   ·   \(errors) error\(errors == 1 ? "" : "s")" }
        text += "   ·   click a line to open it"
        footer.stringValue = text
    }

    private func isNearBottom() -> Bool {
        guard let clip = table.enclosingScrollView?.contentView else { return true }
        let bottom = clip.bounds.origin.y + clip.bounds.height
        return bottom >= table.bounds.height - 40
    }

    private func scrollToBottom() {
        guard rows.count > 0 else { return }
        table.scrollRowToVisible(rows.count - 1)
    }

    @objc private func levelChanged(_ sender: NSSegmentedControl) {
        level = sender.selectedSegment
        reload()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        search = sender.stringValue
        reload()
    }

    @objc private func clicked() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count, rows[row]["divider"] == nil,
              let id = rows[row]["id"] else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        table.reloadData(forRowIndexes: IndexSet(integer: row),
                         columnIndexes: IndexSet(integer: 0))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 22 }
        if rows[row]["divider"] != nil { return 30 }
        guard let id = rows[row]["id"], expanded.contains(id) else { return 22 }
        let extra = rows[row].keys.filter { !["id", "at", "event", "level", "legacy"].contains($0) }
        return 22 + CGFloat(extra.count) * 16 + 14
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        let event = rows[row]

        if let day = event["divider"] {
            let holder = NSView()
            let text = label(readable(day), 10, .semibold, LogWindow.lime.withAlphaComponent(0.75), mono: true)
            let left = rule(), right = rule()
            let bar = NSStackView(views: [left, text, right])
            bar.orientation = .horizontal
            bar.alignment = .centerY
            bar.spacing = 10
            bar.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 14),
                bar.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
                bar.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                left.widthAnchor.constraint(equalToConstant: Col.gutter - 6),
                right.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
            ])
            return holder
        }
        let level = event["level"] ?? "info"
        let colour = tint(level)

        let container = NSView()
        container.wantsLayer = true
        if row.isMultiple(of: 2) {
            container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.022).cgColor
        }

        func chip(_ text: String) -> NSView {
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            holder.widthAnchor.constraint(equalToConstant: Col.source).isActive = true
            guard !text.isEmpty else { return holder }
            let field = label(text, 9.5, .medium, .secondaryLabelColor, mono: true)
            field.translatesAutoresizingMaskIntoConstraints = false
            let pill = NSView()
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            pill.layer?.cornerRadius = 4
            pill.translatesAutoresizingMaskIntoConstraints = false
            pill.addSubview(field)
            holder.addSubview(pill)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                field.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
                field.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
                field.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
                pill.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                pill.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
                pill.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
            ])
            return holder
        }

        func cell(_ text: String, _ width: CGFloat?, _ size: CGFloat,
                  _ colour: NSColor, mono: Bool = true, align: NSTextAlignment = .left) -> NSTextField {
            let field = label(text, size, .regular, colour, mono: mono)
            field.alignment = align
            field.translatesAutoresizingMaskIntoConstraints = false
            if let width { field.widthAnchor.constraint(equalToConstant: width).isActive = true }
            return field
        }

        var message = event["title"] ?? ""
        if let answer = event["answer"] { message = "\(answer)   \(message)" }
        if let choice = event["choice"] { message = "\(choice)   \(message)" }

        let line = NSStackView(views: [
            cell(event["id"] ?? "", Col.gutter, 10, .tertiaryLabelColor, align: .right), vrule(),
            cell(String((event["at"] ?? "").split(separator: "T").last?.prefix(8) ?? ""),
                 Col.time, 10, .secondaryLabelColor), vrule(),
            cell(glyph(level), Col.level, 10.5, colour, align: .center), vrule(),
            cell(event["event"] ?? "", Col.event, 10, colour), vrule(),
            chip(event["source"] ?? event["app"] ?? ""), vrule(),
            cell(message, nil, 11.5, .labelColor, mono: false),
        ])
        line.orientation = .horizontal
        line.spacing = 8
        line.alignment = .centerY
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            line.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 22),
        ])

        if let id = event["id"], expanded.contains(id) {
            let keys = event.keys.filter { !["id", "at", "event", "level", "legacy"].contains($0) }.sorted()
            let detail = NSStackView(views: keys.map { key -> NSView in
                let name = label(key, 10, .medium, .tertiaryLabelColor, mono: true)
                name.translatesAutoresizingMaskIntoConstraints = false
                name.widthAnchor.constraint(equalToConstant: 74).isActive = true
                let value = label(event[key] ?? "", 10.5, .regular,
                                  key == "caller" ? LogWindow.lime : .secondaryLabelColor, mono: true)
                let pair = NSStackView(views: [name, value])
                pair.orientation = .horizontal
                pair.spacing = 10
                pair.alignment = .firstBaseline
                return pair
            })
            detail.orientation = .vertical
            detail.spacing = 3
            detail.alignment = .leading
            detail.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(detail)
            NSLayoutConstraint.activate([
                detail.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                constant: 14 + Col.gutter + 8),
                detail.topAnchor.constraint(equalTo: container.topAnchor, constant: 26),
            ])
        }
        return container
    }
}

// MARK: - panel

final class Pager: NSObject, NSWindowDelegate, NSMenuDelegate {
    private var options: Options
    private let theme: Theme
    private let width: CGFloat
    private let margin: CGFloat = 20

    private var panel: NSPanel!
    private var column: NSStackView!
    private var progress: NSView!
    private var progressWidth: NSLayoutConstraint!
    private var pinButton: Glyph!
    private var compactButton: Glyph!
    private var hideWhenCompact: [NSView] = []

    private var marker: String?
    private var deadline: Date
    private var timer: Timer?
    private var detached = false
    private var held: TimeInterval?
    private var slotNumber = -1
    private var homeCorner = Slots.Corner.bottomRight
    private var base = NSPoint.zero
    private var reflow: Timer?
    private var movingItself = false
    private var shownAt = Date()
    private var ending = false
    private var rateWatch: NSKeyValueObservation?
    private var sizeWatch: NSKeyValueObservation?
    private var loopWatch: NSObjectProtocol?

    init(options: Options) {
        self.options = options
        self.deadline = Date().addingTimeInterval(options.seconds)
        // Without --display this follows the focused window, which is normally
        // the screen you are looking at. Naming one is for the case where a
        // panel should always land on the same monitor whatever you are doing.
        let screens = NSScreen.screens
        let chosen = options.display.flatMap { screens.indices.contains($0) ? screens[$0] : nil }
            ?? NSScreen.main ?? screens.first
        let visible = chosen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let base = min(max(visible.width * 0.26, 340), 480)
        let theme = Theme(scale: base / 380)
        self.theme = theme
        // An explicit width is read in the same units as every other size, so a
        // wider panel still holds its apparent width across the Scaled display
        // settings instead of being tied to one screen.
        self.width = options.width > 0
            ? min((options.width * theme.scale).rounded(), visible.width - 40)
            : base
        super.init()
        build(on: visible)
    }

    private func text(_ string: String, _ size: CGFloat, _ weight: NSFont.Weight,
                      _ colour: NSColor, lines: Int = 1) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        let paragraph = NSMutableParagraphStyle()
        // Word wrapping has to be set here, not just on the field. A paragraph
        // style saying "truncate" wins over the field's own line count and
        // collapses everything onto one line with an ellipsis.
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 1.5 * theme.scale
        paragraph.paragraphSpacing = 5 * theme.scale
        let rendered = NSMutableAttributedString(attributedString:
            Markup.attributed(string, theme: theme, size: size, weight: weight, colour: colour))
        rendered.addAttribute(.paragraphStyle, value: paragraph,
                              range: NSRange(location: 0, length: rendered.length))
        field.attributedStringValue = rendered
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = lines
        field.preferredMaxLayoutWidth = width - theme.pad * 2
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    private func identityIcon() -> NSImageView? {
        guard !options.icon.isEmpty else { return nil }
        let image: NSImage?
        if options.icon.contains("/") {
            image = NSImage(contentsOfFile: (options.icon as NSString).expandingTildeInPath)
        } else {
            image = NSImage(systemSymbolName: options.icon, accessibilityDescription: options.app)?
                .withSymbolConfiguration(.init(pointSize: 11 * theme.scale, weight: .medium))
        }
        guard let image else { return nil }
        let view = NSImageView(image: image)
        view.contentTintColor = .secondaryLabelColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 13 * theme.scale),
            view.heightAnchor.constraint(equalToConstant: 13 * theme.scale),
        ])
        return view
    }

    private func build(on visible: NSRect) {
        let blur = Surface()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = theme.radius
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        blur.onMiddleClick = { [weak self] in self?.close("dismissed", [("via", "middle click")]) }

        // Header carries identity on the left and every control on the right.
        // Who raised this belongs at the top, not stranded in a row underneath
        // the message where it reads as a second set of buttons.
        var identity: [NSView] = []
        if let icon = identityIcon() { identity.append(icon) }
        if !options.app.isEmpty {
            identity.append(text(options.app, 11, .medium, .secondaryLabelColor))
        }
        if !options.source.isEmpty {
            identity.append(text(options.source, 11, .semibold, options.accent))
        }
        if !options.subtitle.isEmpty {
            identity.append(text(options.subtitle, 11, .regular, .tertiaryLabelColor))
        }

        compactButton = Glyph(symbol: options.compact ? "chevron.down" : "chevron.up",
                              tooltip: "Collapse", theme: theme,
                              target: self, action: #selector(toggleCompact))
        pinButton = Glyph(symbol: "pin", tooltip: "Keep on screen", theme: theme,
                          target: self, action: #selector(togglePin), tint: options.accent)
        let remind = Glyph(symbol: "clock", tooltip: "Remind me later", theme: theme,
                           target: self, action: #selector(remindMenu(_:)))
        let close = Glyph(symbol: "xmark", tooltip: "Dismiss", theme: theme,
                          target: self, action: #selector(dismiss))

        let controls = NSStackView(views: [compactButton, pinButton, remind, close])
        controls.orientation = .horizontal
        controls.spacing = 1 * theme.scale

        let heading = text(options.title, 13.5, .semibold, .labelColor, lines: 3)
        var rows: [NSView] = []
        var stretch: [NSView] = []
        var prose: [NSView] = []
        var titleRows = 2

        // With nothing to say about who raised it, the header would be an empty
        // band with four controls floating at its right and the title pushed
        // down under it. In that case the title takes the row itself.
        if identity.isEmpty {
            let combined = NSStackView(views: [heading, spacer(), controls])
            combined.orientation = .horizontal
            combined.alignment = .top
            combined.spacing = theme.inlineGap
            rows = [combined]
            stretch = [combined]
            titleRows = 1
        } else {
            let header = NSStackView(views: identity + [spacer(), controls])
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = theme.inlineGap
            rows = [header, heading]
            stretch = [header, heading]
        }

        // Caption sits directly under the title it describes, as plain dim text.
        if !options.chips.isEmpty {
            let caption = NSStackView(views: options.chips.enumerated().map {
                Chip($1, theme: theme, emphasis: $0 == 0)
            })
            caption.orientation = .horizontal
            caption.spacing = 9 * theme.scale
            rows.append(caption)
        }
        if !options.body.isEmpty {
            let paragraph = text(options.body, 11.5, .regular, .secondaryLabelColor, lines: 0)
            rows.append(paragraph)
            prose.append(paragraph)
        }
        if !options.sparkline.isEmpty {
            rows.append(Sparkline(points: options.sparkline, tint: options.accent, theme: theme))
        }

        stretch += prose
        if let picture = pictureView() { rows.append(picture) }
        for line in audioRows() { rows.append(line); stretch.append(line) }

        var row: NSStackView?
        if !options.actions.isEmpty {
            let buttons = options.actions.enumerated().map { position, action -> NSView in
                let button = Pill(title: action.label, symbol: nil, theme: theme,
                                  target: self, action: #selector(runAction(_:)))
                button.identifier = NSUserInterfaceItemIdentifier(action.command)
                button.tag = position
                button.decorate(icon: loadIcon(options.actionIcon[position]),
                                fill: options.actionFill[position],
                                label: options.actionText[position], theme: theme)
                return button
            }
            let stack = NSStackView(views: buttons + [spacer()])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = theme.inlineGap
            rows.append(stack)
            row = stack
        }

        hideWhenCompact = Array(rows.dropFirst(titleRows))

        column = NSStackView(views: rows)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = theme.rowGap
        column.translatesAutoresizingMaskIntoConstraints = false
        if column.arrangedSubviews.contains(heading) {
            column.setCustomSpacing(theme.rowGap * 0.45, after: heading)
        }
        blur.addSubview(column)

        progress = NSView()
        progress.wantsLayer = true
        progress.layer?.backgroundColor = options.accent.withAlphaComponent(0.5).cgColor
        progress.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(progress)

        progressWidth = progress.widthAnchor.constraint(equalToConstant: width)
        var constraints: [NSLayoutConstraint] = [
            column.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: theme.pad),
            column.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -theme.pad),
            column.topAnchor.constraint(equalTo: blur.topAnchor, constant: theme.pad * 0.7),
            column.bottomAnchor.constraint(lessThanOrEqualTo: blur.bottomAnchor, constant: -theme.pad * 0.85),
            progress.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            progress.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: theme.progressHeight),
            progressWidth,
        ]
        if let row { stretch.append(row) }
        constraints += stretch.map { $0.widthAnchor.constraint(equalTo: column.widthAnchor) }
        NSLayoutConstraint.activate(constraints)

        Playback.shared.onChange = { [weak self] sounding in self?.mediaActivity(sounding) }

        if options.compact { applyCompact(true) }
        blur.layoutSubtreeIfNeeded()
        let height = measuredHeight()

        // "none" means not part of the stack at all, so it neither takes a
        // position nor pushes the next panel up. Without that, a panel raised
        // deliberately off to one side still displaces everything after it.
        var stackOffset = NSPoint.zero
        if options.stack == .none {
            marker = nil
        } else {
            let claimed = Slots.claim(height: height, gap: options.gap,
                                      mode: options.stack, scale: theme.scale,
                                      corner: options.corner ?? .bottomRight)
            marker = claimed.marker
            stackOffset = claimed.offset
            slotNumber = claimed.slot
        }
        let corner = options.corner ?? .bottomRight
        homeCorner = corner
        let placed = corner.origin(in: visible, width: width, height: height, margin: margin)
        let anchor = options.corner != nil ? placed : (Slots.anchor() ?? placed)
        base = anchor
        let origin = NSPoint(
            x: min(max(anchor.x + stackOffset.x + options.offset.x * theme.scale, visible.minX), visible.maxX - width),
            y: min(max(anchor.y + stackOffset.y + options.offset.y * theme.scale, visible.minY), visible.maxY - height)
        )

        Debug.log("placed at (\(Int(origin.x)), \(Int(origin.y))) size \(Int(width))x\(Int(height)) stack=\(options.stack.rawValue)")
        panel = NSPanel(contentRect: NSRect(origin: origin, size: CGSize(width: width, height: height)),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.delegate = self
        panel.contentView = blur

        blur.menu = contextMenu()

        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        Sound.play(options.sound)
        Log.shown(options)
        shownAt = Date()
        startReflow(in: visible)
        if options.pinned { pinButton.lit = true; progress.isHidden = true } else { startTimer() }
    }

    /// A panel below this one closing should not leave a hole. Each stacked
    /// panel watches what is under it and slides down into the space, which is
    /// the only way to do it without the panels talking to each other: they are
    /// separate processes and share nothing but the slot files.
    private func startReflow(in visible: NSRect) {
        guard options.stack == .vertical, marker != nil, slotNumber > 0 else { return }
        reflow = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] tick in
            guard let self, !self.detached, self.marker != nil else { tick.invalidate(); return }
            let below = Slots.occupancy(below: self.slotNumber, corner: self.homeCorner)
            let shift = self.homeCorner.isTop ? -1.0 : 1.0
            let wanted = self.base.y
                + shift * (below.height + self.options.gap * CGFloat(below.count))
                + self.options.offset.y * self.theme.scale
            let target = min(max(wanted, visible.minY), visible.maxY - self.panel.frame.height)
            guard abs(self.panel.frame.origin.y - target) > 0.5 else { return }
            Debug.log("reflow \(Int(self.panel.frame.origin.y)) -> \(Int(target)) (below: \(below.count) panels, \(Int(below.height))pt)")
            var frame = self.panel.frame
            frame.origin.y = target
            self.movingItself = true
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                self.panel.animator().setFrame(frame, display: true)
            }, completionHandler: { self.movingItself = false })
        }
    }

    private func measuredHeight() -> CGFloat {
        (column.fittingSize.height + theme.pad * 1.7).rounded()
    }

    // MARK: media

    /// A still, an animated GIF, or a video with its own controls. The view is
    /// sized to the media itself rather than stretched across the panel. A tall
    /// clip in a full width box is pillarboxed, which reads as the picture
    /// being shoved off to the right for no reason.
    private func pictureView() -> NSView? {
        let content = width - theme.pad * 2
        let cap = (options.mediaHeight > 0 ? options.mediaHeight : 260) * theme.scale

        if !options.video.isEmpty {
            let url = URL(fileURLWithPath: (options.video as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let view = AVPlayerView()
            let player = AVPlayer(url: url)
            view.player = player
            view.controlsStyle = .inline
            view.videoGravity = .resizeAspect
            let box = fit(view, ratio: 0.5625, within: content, cap: cap)
            if options.loop {
                player.actionAtItemEnd = .none
                loopWatch = NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
                ) { [weak player] _ in
                    player?.seek(to: .zero)
                    player?.play()
                }
            }
            rateWatch = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
                self?.mediaActivity(player.rate > 0)
            }
            // Reading the real shape blocks, so the panel opens at 16:9 and
            // corrects itself the moment the item knows how big it is.
            sizeWatch = player.currentItem?.observe(\.presentationSize, options: [.new]) { [weak self] item, _ in
                let shape = item.presentationSize
                guard shape.width > 0 else { return }
                Debug.log("video is \(Int(shape.width))x\(Int(shape.height))")
                let size = Self.display(ratio: shape.height / shape.width, within: content, cap: cap)
                box.width.constant = size.width
                box.height.constant = size.height
                self?.resizeToFit()
            }
            player.play()
            return view
        }

        guard !options.image.isEmpty,
              let image = NSImage(contentsOfFile: (options.image as NSString).expandingTildeInPath),
              image.size.width > 0
        else { return nil }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        fit(view, ratio: image.size.height / image.size.width, within: content, cap: cap)
        return view
    }

    private func loadIcon(_ name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        let looksLikeFile = name.contains("/")
            || [".png", ".jpg", ".jpeg", ".pdf", ".tiff", ".gif"].contains { name.lowercased().hasSuffix($0) }
        if looksLikeFile {
            var path = (name as NSString).expandingTildeInPath
            if !path.hasPrefix("/") { path = Paths.repo.appendingPathComponent(path).path }
            guard let image = NSImage(contentsOfFile: path) else { return nil }
            image.isTemplate = false
            return image
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11 * theme.scale, weight: .semibold))
    }

    /// The size the media actually occupies: as wide as the panel allows, or
    /// narrower when its height would otherwise blow past the cap.
    private static func display(ratio: CGFloat, within content: CGFloat, cap: CGFloat) -> CGSize {
        guard ratio > 0 else { return CGSize(width: content, height: min(content * 0.5625, cap)) }
        let height = min(content * ratio, cap)
        return CGSize(width: min(content, height / ratio).rounded(), height: height.rounded())
    }

    @discardableResult
    private func fit(_ view: NSView, ratio: CGFloat, within content: CGFloat, cap: CGFloat)
        -> (width: NSLayoutConstraint, height: NSLayoutConstraint) {
        view.wantsLayer = true
        view.layer?.cornerRadius = 8 * theme.scale
        view.layer?.masksToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        let size = Self.display(ratio: ratio, within: content, cap: cap)
        let width = view.widthAnchor.constraint(equalToConstant: size.width)
        let height = view.heightAnchor.constraint(equalToConstant: size.height)
        NSLayoutConstraint.activate([width, height])
        return (width, height)
    }


    /// Every clip gets the same name column so the waveforms line up, which is
    /// what makes a list of them readable as a list rather than as five rows.
    private func audioRows() -> [AudioRow] {
        guard !options.audio.isEmpty else { return [] }
        let font = theme.font(11.5, .medium)
        let widest = options.audio
            .map { ($0.label as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let nameWidth = min(max(widest.rounded(.up) + 2, 34 * theme.scale), width * 0.32)

        return options.audio.compactMap { entry in
            guard let url = Sound.url(entry.command),
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            var pick: NSView?
            if let choose = options.choose {
                let button = Pill(title: choose.label, symbol: nil, theme: theme,
                                  target: self, action: #selector(chooseAction(_:)), tint: options.accent)
                button.identifier = NSUserInterfaceItemIdentifier(
                    choose.command
                        .replacingOccurrences(of: "{}", with: entry.label)
                        .replacingOccurrences(of: "{path}", with: url.path))
                button.toolTip = entry.label
                pick = button
            }
            return AudioRow(name: entry.label, url: url, clip: Clip.read(url),
                            nameWidth: nameWidth, theme: theme, tint: options.accent, trailing: pick)
        }
    }

    /// A panel that is making noise should not vanish mid-sentence, so the
    /// countdown is held while anything plays and resumes where it left off.
    private func mediaActivity(_ active: Bool) {
        guard !options.pinned else { return }
        if active {
            if held == nil { held = max(deadline.timeIntervalSinceNow, 10) }
            timer?.invalidate()
        } else if let remaining = held {
            held = nil
            deadline = Date().addingTimeInterval(remaining)
            startTimer()
        }
    }

    // MARK: right click

    /// Everything reachable by clicking is reachable here too, so the buttons
    /// can stay sparse without hiding functionality.
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        for action in options.actions {
            let item = NSMenuItem(title: action.label, action: #selector(runMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.command
            item.tag = options.actions.firstIndex { $0.label == action.label } ?? -1
            menu.addItem(item)
        }
        if !options.actions.isEmpty { menu.addItem(.separator()) }

        let pin = NSMenuItem(title: options.pinned ? "Unpin" : "Keep on screen",
                             action: #selector(togglePin), keyEquivalent: "")
        pin.target = self
        menu.addItem(pin)

        let compact = NSMenuItem(title: options.compact ? "Expand" : "Compact",
                                 action: #selector(toggleCompact), keyEquivalent: "")
        compact.target = self
        menu.addItem(compact)

        let remind = NSMenuItem(title: "Remind me", action: nil, keyEquivalent: "")
        remind.submenu = remindSubmenu()
        menu.addItem(remind)

        menu.addItem(.separator())
        let copyTitleItem = NSMenuItem(title: "Copy title", action: #selector(copyTitle), keyEquivalent: "")
        copyTitleItem.target = self
        menu.addItem(copyTitleItem)
        for entry in options.copies {
            let item = NSMenuItem(title: entry.label, action: #selector(copyValue(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.command
            menu.addItem(item)
        }

        let dismiss = NSMenuItem(title: "Dismiss", action: #selector(dismiss), keyEquivalent: "")
        dismiss.target = self
        menu.addItem(dismiss)
        return menu
    }

    private func remindSubmenu() -> NSMenu {
        let menu = NSMenu()
        for (label, seconds) in [("in 10 minutes", 600), ("in 30 minutes", 1800),
                                 ("in an hour", 3600), ("in 3 hours", 10800),
                                 ("tomorrow at 9", secondsUntilTomorrow())] {
            let item = NSMenuItem(title: label, action: #selector(remind(_:)), keyEquivalent: "")
            item.target = self
            item.tag = seconds
            menu.addItem(item)
        }
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The panel outlives its menu's labels, so refresh the toggles on open.
        for item in menu.items {
            if item.action == #selector(togglePin) { item.title = options.pinned ? "Unpin" : "Keep on screen" }
            if item.action == #selector(toggleCompact) { item.title = options.compact ? "Expand" : "Compact" }
        }
    }

    // MARK: actions

    /// The pressed label goes to stdout. A caller running pager in the
    /// foreground therefore blocks until you answer and reads the answer back,
    /// which is the whole callback story. Fire and forget callers ignore it.
    private func emit(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        FileHandle.standardOutput.write(data)
    }

    @objc private func runAction(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        let label = options.actions.indices.contains(sender.tag) ? options.actions[sender.tag].label : ""
        if !label.isEmpty { emit(label) }
        if !command.isEmpty { shell(command) }
        close("answered", [("answer", label)])
    }

    /// Marking a row is not the same as answering the panel: you are going down
    /// a list, so it runs the command, lights the button, and stays open.
    @objc private func chooseAction(_ sender: NSButton) {
        guard let command = sender.identifier?.rawValue else { return }
        if let name = sender.toolTip {
            emit(name)
            Log.write("chose", [("choice", name), ("title", options.title)])
        }
        if !command.isEmpty { shell(command) }
        (sender as? Pill)?.lit = true
    }

    @objc private func runMenuAction(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        let label = options.actions.indices.contains(sender.tag) ? options.actions[sender.tag].label : ""
        if !label.isEmpty { emit(label) }
        if !command.isEmpty { shell(command) }
        close("answered", [("answer", label), ("via", "menu")])
    }

    @objc private func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    @objc private func copyTitle() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(options.title, forType: .string)
    }

    @objc private func togglePin() {
        options.pinned.toggle()
        pinButton.lit = options.pinned
        pinButton.set(symbol: options.pinned ? "pin.fill" : "pin")
        progress.isHidden = options.pinned
        if options.pinned {
            timer?.invalidate()
        } else {
            deadline = Date().addingTimeInterval(options.seconds)
            startTimer()
        }
    }

    @objc private func toggleCompact() {
        applyCompact(!options.compact)
        compactButton.set(symbol: options.compact ? "chevron.down" : "chevron.up")
        resizeToFit()
    }

    private func applyCompact(_ on: Bool) {
        options.compact = on
        hideWhenCompact.forEach { $0.isHidden = on }
    }

    private func resizeToFit() {
        panel.contentView?.layoutSubtreeIfNeeded()
        let height = measuredHeight()
        var frame = panel.frame
        frame.origin.y += frame.height - height     // hold the top edge still
        frame.size.height = height
        Debug.log("resized to \(height)")
        movingItself = true
        panel.setFrame(frame, display: true, animate: true)
        movingItself = false
        if let marker, !detached {
            try? "\(getpid()) \(Int(height))\n".write(toFile: marker, atomically: true, encoding: .utf8)
        }
    }

    @objc private func remindMenu(_ sender: NSButton) {
        remindSubmenu().popUp(positioning: nil,
                              at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    private func secondsUntilTomorrow() -> Int {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        var parts = calendar.dateComponents([.year, .month, .day], from: tomorrow)
        parts.hour = 9
        let target = calendar.date(from: parts) ?? Date().addingTimeInterval(86400)
        return max(60, Int(target.timeIntervalSinceNow))
    }

    @objc private func remind(_ sender: NSMenuItem) {
        // Re-raise itself later by re-running the same argv after a sleep.
        let quoted = CommandLine.arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        shell("sleep \(sender.tag); " + quoted.joined(separator: " "))
        close("snoozed", [("for", sender.tag)])
    }

    @objc private func dismiss() { close() }

    private func shell(_ command: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", command]
        try? task.run()
    }

    // MARK: timer and window

    private func startTimer() {
        timer?.invalidate()
        // Tick roughly once per point the bar actually moves, rather than at a
        // fixed 30fps. A three minute panel goes from 5400 wakeups to about 400.
        let step = min(0.5, max(1.0 / 30.0, options.seconds / Double(max(width, 1))))
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] tick in
            guard let self, !self.options.pinned else { tick.invalidate(); return }
            let left = self.deadline.timeIntervalSinceNow
            if left <= 0 { tick.invalidate(); self.close("expired"); return }
            self.progressWidth.constant = self.width * CGFloat(left / self.options.seconds)
        }
    }

    /// Dragging detaches a panel: it gives up its slot so the stack closes the
    /// gap, and where it was dropped becomes the anchor for everything after.
    func windowDidMove(_ notification: Notification) {
        Debug.log("moved to \(panel.frame.origin)")
        guard panel.isVisible, !movingItself else { return }
        if !detached, let marker {
            detached = true
            try? FileManager.default.removeItem(atPath: marker)
            self.marker = nil
        }
        Slots.remember(anchor: panel.frame.origin)
    }

    private func close(_ reason: String = "dismissed", _ extra: [(String, Any)] = []) {
        if !ending {
            ending = true
            Log.write(reason, level: reason == "expired" ? "debug" : "info",
                      [("alive", Date().timeIntervalSince(shownAt)),
                       ("title", options.title), ("source", options.source)] + extra)
        }
        reflow?.invalidate()
        Playback.shared.onChange = nil          // stopping must not revive the countdown
        Playback.shared.stop()
        rateWatch = nil
        sizeWatch = nil
        if let loopWatch { NotificationCenter.default.removeObserver(loopWatch) }
        timer?.invalidate()
        if let marker { try? FileManager.default.removeItem(atPath: marker) }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            self.panel.orderOut(nil)
            NSApp.terminate(nil)
        })
    }
}

// MARK: - entry

let EXAMPLES = """
  pager recipes. Copy one and change the words.

  Something failed, and you want it to stay until seen:

    pager --title "Deploy failed on production" \\
          --app "coolify" --icon "exclamationmark.triangle" \\
          --source "deploy" --accent "#ff5f57" --sound alarm \\
          --body "3 of 12 containers unhealthy after rollout" \\
          --chip "production" --chip "8f21ac3" \\
          --action "Logs:open https://coolify.example.com/logs" \\
          --action "Rollback:/usr/local/bin/rollback production" \\
          --pinned

  A long job finished, and you are probably in another window:

    pager --title "Test suite passed, 412 tests in 3m11s" \\
          --source "ci" --chip "main" --sound rise \\
          --action "Open PR:open https://github.com/you/repo/pull/42" \\
          --seconds 120

  A periodic summary, with a shape rather than a number:

    pager --title "Sales are up 34% this week" \\
          --app "acme" --accent "#28c840" --sound glass \\
          --body "12 new subscriptions, 2 churned." \\
          --sparkline "4,6,5,9,8,12,17,16,22" \\
          --chip "mrr $1,840" \\
          --action "Dashboard:open https://example.com/admin" \\
          --seconds 600

  Something needs a decision, so give it real buttons:

    pager --title "Pull request ready to merge" \\
          --source "github" --chip "asks" --chip "#42" --sound bell \\
          --action "Merge:gh pr merge 42 --squash" \\
          --action "Review:gh pr view 42 --web" \\
          --copy "Copy branch name:feature/native-toast" \\
          --pinned

  Something to look at, rather than read:

    pager --title "Tests are green" --sound rise \\
          --image ~/cats/celebrate.gif

    pager --title "New demo cut is ready" --source render \\
          --video ~/renders/demo.mp4 \\
          --action "Open folder:open ~/renders"

  Something to listen to and answer:

    pager --title "Approve this take?" --source studio --pinned \\
          --audio "take 3:~/vo/take3.wav" \\
          --action "Ship it:./publish.sh take3" \\
          --action "Redo:./record.sh"

  A list to go down, one row per clip. --choose puts a button on every row,
  {} becomes that row's name and {path} its file. Marking one keeps the
  panel open, so you can work through the whole list.

    pager --title "Which of these survive?" --width 540 --pinned \\
          --audio "chirp:chirp" --audio "bell:bell" --audio "glass:glass" \\
          --choose "Keep:echo {} >> ~/.pager/kept"

  Wiring it into code. This is the common case: no agent runs pager, your
  program does, forever.

    # bash
    trap 'pager --title "backup.sh failed at line $LINENO" --accent "#ff5f57" --pinned' ERR

    # python
    import subprocess
    def notify(title, **kw):
        args = ["pager", "--title", title]
        for label, command in kw.pop("actions", {}).items():
            args += ["--action", f"{label}:{command}"]
        subprocess.Popen(args)

  Sound. Run `pager --sounds` to hear all ten in order.

    chirp  agents talking, the default voice
    tick   something small and frequent
    drop   something was captured
    thump  register it without interrupting
    wood   a task finished
    glass  a summary, gentle
    rise   it worked
    fall   it did not
    bell   a decision is waiting
    alarm  something is actually down

  Silence is the default. Add --sound only when hearing it beats seeing it,
  and use the quiet end of that list for anything that fires often.

  Notes worth following:

    Use --pinned for anything that must not be missed. Everything else
    disappears on its own, which is the point.

    Actions run through /bin/sh. Never interpolate untrusted text into one.

    Colour carries meaning: red #ff5f57 for failure, green #28c840 for money
    and good news, blue #3b8eea for information, lime #c8ff00 for agents.

    One panel per event. Do not raise five in a loop when one with a count
    would do.

"""

// Only as the first argument. Scanning every argument meant a --chip whose
// value happened to be "--examples" printed the recipes instead of a panel.
if CommandLine.arguments.dropFirst().first == "--sounds" {
    // Ordered gentlest to loudest, not alphabetically, so an audition does
    // not open with the alarm.
    let roster = [
        ("chirp", "two swept tones. the default voice for agents"),
        ("tick",  "filtered noise, no pitch. something small and frequent"),
        ("drop",  "a droplet, pitch rising. something was captured"),
        ("thump", "sub sine, felt more than heard. barely interrupt"),
        ("wood",  "a struck bar. a task finished"),
        ("glass", "beating partials, shimmer tail. a summary, gentle"),
        ("rise",  "three tones up a major triad. it worked"),
        ("fall",  "two tones down a minor third. it did not"),
        ("bell",  "FM, metallic and long. a decision is waiting"),
        ("alarm", "three gated pulses. something is actually down"),
    ]
    print("\n  pager sounds. playing each in turn.\n")
    for (name, meaning) in roster where Sound.names.contains(name) {
        print("    " + name.padding(toLength: 8, withPad: " ", startingAt: 0) + meaning)
        fflush(stdout)
        if let url = Sound.url(name), let sound = NSSound(contentsOf: url, byReference: false) {
            sound.play()
            Thread.sleep(forTimeInterval: max(0.6, sound.duration) + 0.25)
        }
    }
    print("\n  use one with:  pager --title \"…\" --sound bell")
    print("  replace one by dropping your own at ~/.pager/sounds/<name>.wav\n")
    exit(0)
}

let VERSION = "1.0.0"

if ["--version", "-v"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    print("pager \(VERSION)")
    exit(0)
}

// Geometry, so a script can work out where a panel will land.
if CommandLine.arguments.dropFirst().first == "--screen" {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let main = NSScreen.main ?? NSScreen.screens[0]
    let primary = NSScreen.screens.first ?? main
    let v = main.visibleFrame, f = main.frame
    print("visible \(Int(v.minX)) \(Int(v.minY)) \(Int(v.width)) \(Int(v.height))")
    print("frame \(Int(f.minX)) \(Int(f.minY)) \(Int(f.width)) \(Int(f.height))")
    print("primary \(Int(primary.frame.width)) \(Int(primary.frame.height))")
    print("screens \(NSScreen.screens.count)")
    for (index, screen) in NSScreen.screens.enumerated() {
        let box = screen.visibleFrame
        let here = screen == NSScreen.main ? "  (focused)" : ""
        print("display \(index) \(Int(box.width))x\(Int(box.height)) at \(Int(box.minX)),\(Int(box.minY))\(here)")
    }
    exit(0)
}

if ["log", "--log"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    LogView.show(Array(CommandLine.arguments.dropFirst(2)))
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "--tour" {
    let script = Paths.repo.appendingPathComponent("tour/tour.sh").path
    guard FileManager.default.isReadableFile(atPath: script) else {
        FileHandle.standardError.write("no tour at \(script)\n".data(using: .utf8)!)
        exit(1)
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [script] + Array(CommandLine.arguments.dropFirst(2))
    try? task.run()
    task.waitUntilExit()
    exit(task.terminationStatus)
}

if CommandLine.arguments.dropFirst().first == "--examples" {
    print(EXAMPLES)
    exit(0)
}

let options = Options.parse(CommandLine.arguments)
guard !options.title.isEmpty else {
    FileHandle.standardError.write("""
    usage: pager --title <text> [options]

      --source <name>        who is talking, shown in the accent colour
      --subtitle <text>      dim text beside the source
      --body <text>          a paragraph under the title
      --app <name>           what raised this, e.g. "Claude Code"
      --icon <symbol|path>   SF Symbol name or an image file
      --chip <text>          caption under the title, repeatable
      --copy "Label:text"    a right click copy entry, repeatable
      --sparkline "1,4,3,9"  a small line chart
      --action "Label:cmd"   a button, repeatable. Its label goes to stdout.
      --action-icon <n|path> decorate the action just declared
      --action-fill "#hex"   its background
      --action-text "#hex"   its label colour
      --image <path>         a still or an animated GIF
      --video <path>         inline video with controls
      --audio "Name:path"    a player row with a waveform, repeatable
      --choose "Label:cmd"   a button on every audio row, {} is the name
      --width <points>       wider panel, worth it for lists
      --accent "#rrggbb"     defaults to acid lime
      --stack <mode>         vertical, cascade or none. default vertical
      --gap <points>         space between stacked panels, default 12
      --corner <name>        bottom-right (default), bottom-left,
                             top-right, top-left. Each stacks separately
      --display <n>          which monitor. default follows your focus,
                             see `pager --screen` for the list
      --offset "dx,dy"       nudge away from the corner
      --loop                 repeat the video instead of stopping
      --seconds <n>          time on screen, default 180
      --sound <name|path>    a bundled sound, a .wav path, or none
      --pinned               start pinned, no timer
      --compact              start collapsed

      --tour                 a guided tour of everything above
      --sounds               play the bundled sounds in turn
      --examples             copy-pasteable recipes
      --version              print the version

    pager log                what has been paging you, newest last
      --window               open it as a window instead
      --json                 one object per line, the way it was written
                             (also what you get when the output is piped)
      -n <count>             how many lines, default 40
      -f, --follow           keep printing as they arrive
      --source / --app / --event / --caller / --level / --grep
      --errors               only what went wrong
      --stats                who calls pager, and how panels end
      --path                 where the file is

    Text supports **bold**, *italic* and `code`.

    """.data(using: .utf8)!)
    exit(1)
}

let app = NSApplication.shared
// .accessory keeps it out of the Dock and the app switcher, and stops it taking
// focus from whatever is in front.
app.setActivationPolicy(.accessory)
let pager = Pager(options: options)
app.run()
