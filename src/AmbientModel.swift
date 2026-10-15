import Foundation

// MARK: - ambient: the data
//
// Everything here is plain values and pure functions, so `pager ambient
// --selftest` can check it without a window. The overlay, the hub client
// and the socket build on top of this file and nothing here knows about them.

/// Where the ambient stream keeps its files. `PAGER_AMBIENT_DIR` moves all of
/// them at once, which is what the tests use so they never touch real history.
enum AmbientPaths {
    static var directory: String {
        if let dir = ProcessInfo.processInfo.environment["PAGER_AMBIENT_DIR"], !dir.isEmpty {
            return (dir as NSString).expandingTildeInPath
        }
        return Slots.directory
    }
    static var socket: String { directory + "/ambient.sock" }
    static var settings: String { directory + "/ambient.json" }
    static var state: String { directory + "/ambient-state.json" }
    static var history: String { directory + "/events.jsonl" }
    static var log: String { directory + "/ambient.log" }
    static var lock: String { directory + "/ambient.lock" }

    static func ensure() {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
}

// MARK: - dates

enum AmbientTime {
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()

    static func parse(_ text: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? plain.date(from: text)
    }

    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return plain.string(from: date)
    }

    /// Keeps milliseconds when there are any, so a stored event reads back equal.
    static func precise(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        let t = date.timeIntervalSince1970
        return t == t.rounded() ? plain.string(from: date) : fractional.string(from: date)
    }

    /// `now`, `12s`, `4m`, `3h`, `2d`. A clock a little behind the server's
    /// gives negative ages, which are also `now`.
    static func age(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 5 else { return "now" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

// MARK: - presentation vocabulary

enum EventLayout: String, Codable, CaseIterable, Identifiable {
    case split, inline
    var id: Self { self }
    var label: String { self == .split ? "Split columns" : "Inline" }
}

enum TextEffect: String, Codable, CaseIterable, Identifiable {
    case none, blink, flash, highlight, wave, gradient
    var id: Self { self }
    var label: String {
        switch self {
        case .none: return "None"
        case .blink: return "Blink"
        case .flash: return "Flash text"
        case .highlight: return "Flash highlight"
        case .wave: return "Wave"
        case .gradient: return "Moving gradient"
        }
    }
}

enum EffectTarget: String, Codable, CaseIterable, Identifiable {
    case emphasis, message
    var id: Self { self }
    var label: String { self == .emphasis ? "Emphasized text" : "Whole message" }
}

enum Severity: String, CaseIterable {
    case debug, info, notice, warn, error, critical
    var rank: Int { Severity.allCases.firstIndex(of: self) ?? 1 }
    static func rank(_ text: String?) -> Int { Severity(rawValue: text ?? "info")?.rank ?? 1 }
}

/// Seconds, or until dismissed.
enum Lifetime: Equatable, Codable {
    case seconds(Double)
    case sticky

    static let maximum: Double = 86_400

    static func parse(_ text: String) -> Lifetime? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "sticky" { return .sticky }
        guard let value = Double(trimmed), value.isFinite, value >= 1, value <= maximum else { return nil }
        return .seconds(value)
    }

    var isSticky: Bool { self == .sticky }

    var clamped: Lifetime {
        switch self {
        case .sticky: return .sticky
        case .seconds(let s): return .seconds(s.isFinite ? min(Lifetime.maximum, max(1, s)) : 60)
        }
    }

    var label: String {
        switch self {
        case .sticky: return "sticky"
        case .seconds(let s): return s == s.rounded() ? "\(Int(s))" : "\(s)"
        }
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let number = try? box.decode(Double.self) {
            self = .seconds(number)
        } else if let text = try? box.decode(String.self), let value = Lifetime.parse(text) {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(in: box, debugDescription: "lifetime is seconds or \"sticky\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .sticky: try box.encode("sticky")
        case .seconds(let s):
            if s == s.rounded() { try box.encode(Int(s)) } else { try box.encode(s) }
        }
    }
}

/// Presentation hints carried by an event. Unknown words are kept as text and
/// ignored when resolved, so one odd value never drops the whole event.
struct AmbientDisplay: Codable, Equatable {
    var lifetime: Lifetime?
    var layout: String?
    var effect: String?
    var target: String?
    var period: Double?
    var color: String?
    var lines: Int?

    init(lifetime: Lifetime? = nil, layout: String? = nil, effect: String? = nil, target: String? = nil,
         period: Double? = nil, color: String? = nil, lines: Int? = nil) {
        self.lifetime = lifetime; self.layout = layout; self.effect = effect; self.target = target
        self.period = period; self.color = color; self.lines = lines
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lifetime = try? c.decodeIfPresent(Lifetime.self, forKey: .lifetime)
        layout = try? c.decodeIfPresent(String.self, forKey: .layout)
        effect = try? c.decodeIfPresent(String.self, forKey: .effect)
        target = try? c.decodeIfPresent(String.self, forKey: .target)
        period = try? c.decodeIfPresent(Double.self, forKey: .period)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        lines = try? c.decodeIfPresent(Int.self, forKey: .lines)
    }

    var isEmpty: Bool { self == AmbientDisplay() }

    /// What a hub accepts. `lines` is Pager's own and a hub would reject it.
    var forHub: AmbientDisplay? {
        var copy = self
        copy.lines = nil
        return copy.isEmpty ? nil : copy
    }
}

// MARK: - the event

/// One line of the stream, the record a hub hands its readers (docs/protocol.md). Anything
/// in here is data: it is shown, filtered and stored, never run.
struct AmbientEvent: Codable, Equatable, Identifiable {
    var id: String
    var cursor: String?
    var source: String
    var sourceName: String?
    var sourceColor: String?
    var type: String?
    var severity: String?
    var text: String
    var detail: String?
    var subject: String?
    var url: String?
    var occurredAt: Date?
    var receivedAt: Date?
    var display: AmbientDisplay?
    var dismissedAt: Date?
    /// Pager's own fields, never taken from a hub. `origin` is `hub`, `local`
    /// or `demo`; `connection` is the id of the connection it came through.
    var origin: String?
    var connection: String?

    enum CodingKeys: String, CodingKey {
        case id, cursor, source, type, severity, text, detail, subject, url, display, origin, connection
        case sourceName = "source_name", sourceColor = "source_color"
        case occurredAt = "occurred_at", receivedAt = "received_at", dismissedAt = "dismissed_at"
    }

    init(id: String, source: String, text: String) {
        self.id = id
        self.source = source
        self.text = text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func string(_ key: CodingKeys) -> String? {
            if let text = try? c.decodeIfPresent(String.self, forKey: key) { return text }
            if let number = try? c.decodeIfPresent(Int64.self, forKey: key) { return String(number) }
            return nil
        }
        func date(_ key: CodingKeys) -> Date? { string(key).flatMap(AmbientTime.parse) }
        guard let id = string(.id), !id.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(codingPath: [], debugDescription: "event without id"))
        }
        self.id = id
        cursor = string(.cursor)
        source = string(.source) ?? "unknown"
        sourceName = string(.sourceName)
        sourceColor = string(.sourceColor)
        type = string(.type)
        severity = string(.severity)
        text = string(.text) ?? ""
        detail = string(.detail)
        subject = string(.subject)
        url = string(.url)
        occurredAt = date(.occurredAt)
        receivedAt = date(.receivedAt)
        display = try? c.decodeIfPresent(AmbientDisplay.self, forKey: .display)
        dismissedAt = date(.dismissedAt)
        origin = string(.origin)
        connection = string(.connection)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(cursor, forKey: .cursor)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sourceName, forKey: .sourceName)
        try c.encodeIfPresent(sourceColor, forKey: .sourceColor)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(severity, forKey: .severity)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(subject, forKey: .subject)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(occurredAt.map(AmbientTime.precise), forKey: .occurredAt)
        try c.encodeIfPresent(receivedAt.map(AmbientTime.precise), forKey: .receivedAt)
        if let display, !display.isEmpty { try c.encode(display, forKey: .display) }
        try c.encodeIfPresent(dismissedAt.map(AmbientTime.precise), forKey: .dismissedAt)
        try c.encodeIfPresent(origin, forKey: .origin)
        try c.encodeIfPresent(connection, forKey: .connection)
    }

    static func decode(_ data: Data) -> AmbientEvent? { try? JSONDecoder().decode(AmbientEvent.self, from: data) }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    var label: String { sourceName ?? source }
    var fromHub: Bool { origin == "hub" && connection != nil }
    /// Ids are only unique within one hub, so everything keys on both.
    var key: String { (connection ?? "local") + "/" + id }
    /// When it happened, for the age on the line.
    var happened: Date? { occurredAt ?? receivedAt }

    /// Ids for events made on this Mac. A hub's are its own business.
    static func localID(now: Date = Date()) -> String {
        let millis = UInt64(now.timeIntervalSince1970 * 1000)
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let tail = String((0..<5).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
        return "loc_" + String(millis, radix: 36) + tail
    }
}

// MARK: - settings

/// One hub this Mac reads from. The key is not in here: it lives in the
/// Keychain under the connection's id, or in an env file the user points at.
struct AmbientConnection: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var url: String
    /// Narrow the stream to these sources. Empty means everything the key may read.
    var sources: [String] = []
    var enabled = true
    /// Optional env file (`NAME=value` lines) to read the key from instead of
    /// the Keychain, and which variable in it. Handy for a LaunchAgent.
    var keyFile: String?
    var keyVar: String?

    enum CodingKeys: String, CodingKey {
        case id, name, url, sources, enabled
        case keyFile = "key_file", keyVar = "key_var"
    }

    init(id: String, name: String, url: String, sources: [String] = [], enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.sources = sources; self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decode(String.self, forKey: .url)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)).flatMap { $0 } ?? AmbientConnection.defaultName(url)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)).flatMap { $0 } ?? AmbientConnection.slug(name)
        sources = ((try? c.decodeIfPresent([String].self, forKey: .sources)) ?? nil) ?? []
        enabled = ((try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? true
        keyFile = (try? c.decodeIfPresent(String.self, forKey: .keyFile)) ?? nil
        keyVar = (try? c.decodeIfPresent(String.self, forKey: .keyVar)) ?? nil
    }

    static func slug(_ text: String) -> String {
        let lowered = text.lowercased().map { ($0.isLetter || $0.isNumber) && $0.isASCII ? $0 : "-" }
        let joined = String(lowered).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "hub" : String(joined.prefix(32))
    }

    static func defaultName(_ url: String) -> String {
        URLComponents(string: url)?.host?.split(separator: ".").first.map(String.init) ?? "hub"
    }

    /// The base URL, normalised, or nil when it is not an http(s) URL.
    var base: URL? { AmbientConnection.normalise(url) }

    static func normalise(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              components.host != nil else { return nil }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct SourceOverride: Codable, Equatable {
    var lifetime: Lifetime?
    var color: String?
    var mute: Bool?
}

/// `~/.pager/ambient.json`. Every field is optional on disk, so a file written
/// by an older build, or by hand with three keys in it, still loads.
struct AmbientSettings: Codable, Equatable {
    var width = 480.0
    var rowGap = 2.0
    var rowPadding = 0.0
    var sidePadding = 0.0
    var columnGap = 8.0
    var sourceWidth = 90.0
    var fontSize = 12.0
    var lifetime = 60.0
    var maxLines = 20
    var lines = 1
    var corner = "top-right"
    var screen = 0
    var layout = EventLayout.split
    var effect = TextEffect.none
    var target = EffectTarget.emphasis
    var period = 2.0
    var cards = false
    var icons = false
    var backdrop = false
    /// 0 to 1: the dark halo on the glyphs and the soft shade behind the stream,
    /// so a line reads over a white page as well as over a dark one.
    var shade = 0.6
    var details = false
    var ages = true
    var middleClick = true
    var sources: [String: SourceOverride] = [:]
    var connections: [AmbientConnection] = []

    enum CodingKeys: String, CodingKey {
        case width, lifetime, lines, corner, screen, layout, effect, target, period
        case cards, icons, backdrop, shade, details, ages, sources, connections
        case rowGap = "row_gap", rowPadding = "row_padding", sidePadding = "side_padding"
        case columnGap = "column_gap", sourceWidth = "source_width", fontSize = "font_size"
        case maxLines = "max_lines", middleClick = "middle_click"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AmbientSettings()
        func v<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        width = v(.width, d.width); rowGap = v(.rowGap, d.rowGap)
        rowPadding = v(.rowPadding, d.rowPadding); sidePadding = v(.sidePadding, d.sidePadding)
        columnGap = v(.columnGap, d.columnGap); sourceWidth = v(.sourceWidth, d.sourceWidth)
        fontSize = v(.fontSize, d.fontSize); lifetime = v(.lifetime, d.lifetime)
        maxLines = v(.maxLines, d.maxLines); lines = v(.lines, d.lines)
        corner = v(.corner, d.corner); screen = v(.screen, d.screen)
        layout = v(.layout, d.layout); effect = v(.effect, d.effect); target = v(.target, d.target)
        period = v(.period, d.period); cards = v(.cards, d.cards); icons = v(.icons, d.icons)
        backdrop = v(.backdrop, d.backdrop); shade = v(.shade, d.shade); details = v(.details, d.details); ages = v(.ages, d.ages)
        middleClick = v(.middleClick, d.middleClick); sources = v(.sources, d.sources)
        connections = v(.connections, d.connections)
        sanitize()
    }

    static let corners = ["top-right", "top-left", "bottom-right", "bottom-left"]

    /// Hand-edited files get the same bounds the sliders have.
    mutating func sanitize() {
        func clamp(_ x: Double, _ lo: Double, _ hi: Double, _ fallback: Double) -> Double {
            x.isFinite ? min(hi, max(lo, x)) : fallback
        }
        width = clamp(width, 200, 1200, 480)
        rowGap = clamp(rowGap, 0, 24, 2)
        rowPadding = clamp(rowPadding, 0, 16, 0)
        sidePadding = clamp(sidePadding, 0, 24, 0)
        columnGap = clamp(columnGap, 0, 32, 8)
        sourceWidth = clamp(sourceWidth, 30, 200, 90)
        fontSize = clamp(fontSize, 9, 20, 12)
        lifetime = clamp(lifetime, 1, Lifetime.maximum, 60)
        period = clamp(period, 0.5, 10, 2)
        maxLines = min(100, max(1, maxLines))
        shade = clamp(shade, 0, 1, 0.6)
        lines = min(5, max(1, lines))
        screen = max(0, screen)
        if !AmbientSettings.corners.contains(corner) { corner = "top-right" }
        var ids = Set<String>()
        connections = connections.filter { ids.insert($0.id).inserted }
    }

    static func load(_ path: String = AmbientPaths.settings) -> AmbientSettings {
        guard let data = FileManager.default.contents(atPath: path),
              let settings = try? JSONDecoder().decode(AmbientSettings.self, from: data) else { return AmbientSettings() }
        return settings
    }

    func save(_ path: String = AmbientPaths.settings) {
        AmbientPaths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

// MARK: - resolving how a line looks and how long it stays

struct ResolvedPresentation: Equatable {
    var lifetime: Lifetime
    var layout: EventLayout
    var effect: TextEffect
    var target: EffectTarget
    var period: Double
    var accent: String?
    var sourceColor: String?
    var lines: Int
    var muted: Bool
}

enum AmbientRules {
    /// Pager's per-source settings beat the event's own hints, which beat the
    /// global defaults. The protocol calls them hints for exactly this reason.
    static func resolve(_ event: AmbientEvent, _ settings: AmbientSettings) -> ResolvedPresentation {
        let display = event.display ?? AmbientDisplay()
        let source = settings.sources[event.source]
        let lifetime = (source?.lifetime ?? display.lifetime ?? .seconds(settings.lifetime)).clamped
        let period = display.period.map { $0.isFinite ? min(10, max(0.5, $0)) : settings.period } ?? settings.period
        return ResolvedPresentation(
            lifetime: lifetime,
            layout: display.layout.flatMap(EventLayout.init(rawValue:)) ?? settings.layout,
            effect: display.effect.flatMap(TextEffect.init(rawValue:)) ?? settings.effect,
            target: display.target.flatMap(EffectTarget.init(rawValue:)) ?? settings.target,
            period: period,
            accent: validHex(display.color) ?? accent(for: event),
            sourceColor: validHex(source?.color) ?? validHex(event.sourceColor),
            lines: min(5, max(1, display.lines ?? settings.lines)),
            muted: source?.mute ?? false)
    }

    /// The emphasis colour when the event does not pick one: bad news red,
    /// warnings orange, money mint, the rest by kind as in the prototype.
    static func accent(for event: AmbientEvent) -> String? {
        switch Severity(rawValue: event.severity ?? "") {
        case .critical, .error: return "#ff5f57"
        case .warn: return "#ffb340"
        default: break
        }
        switch (event.type ?? "").lowercased() {
        case "failure", "error", "down", "failed": return "#ff5f57"
        case "warning": return "#ffb340"
        case "sale", "payment": return "#63e6be"
        case "deploy", "success", "recovery", "up", "backup": return "#5fd068"
        case "merge", "pr.merged": return "#bf8cff"
        case "pr", "pr.opened": return "#5ac8fa"
        default: return nil
        }
    }

    static func validHex(_ text: String?) -> String? {
        guard var hex = text?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, Int(hex, radix: 16) != nil else { return nil }
        return "#" + hex.lowercased()
    }

    /// The moment a line's lifetime counts from. The hub's receive time is the
    /// one clock every reader shares; a sender's clock may be anything. A
    /// timestamp from the future means our clock is behind, so it is now.
    static func anchor(_ event: AmbientEvent, now: Date) -> Date {
        let stamp = event.receivedAt ?? event.occurredAt ?? now
        return min(stamp, now)
    }

    struct Decision: Equatable {
        var show: Bool
        var expires: Date?
        /// Arrived as it happened, rather than in a catch-up. Only fresh lines animate.
        var fresh: Bool
    }

    static let freshWindow: TimeInterval = 10

    /// Whether a line belongs on screen right now. After a reconnect the
    /// catch-up goes through here too, so only lines still inside their
    /// lifetime come back, and they come back quietly.
    static func decide(_ event: AmbientEvent, _ resolved: ResolvedPresentation, now: Date) -> Decision {
        let anchor = anchor(event, now: now)
        let fresh = now.timeIntervalSince(anchor) < freshWindow
        if event.dismissedAt != nil || resolved.muted { return Decision(show: false, expires: nil, fresh: fresh) }
        switch resolved.lifetime {
        case .sticky:
            return Decision(show: true, expires: nil, fresh: fresh)
        case .seconds(let seconds):
            let expires = anchor.addingTimeInterval(seconds)
            return Decision(show: expires.timeIntervalSince(now) > 0.5, expires: expires, fresh: fresh)
        }
    }

    /// Exponential, capped at a minute, with jitter so two Macs that lost the
    /// same connection do not knock on the door in step.
    static func backoff(attempt: Int, random: Double = Double.random(in: 0...1)) -> TimeInterval {
        let base = min(60, pow(2, Double(max(0, min(attempt, 10)))))
        return base * (0.5 + 0.5 * random)
    }
}

// MARK: - server-sent events

struct SSEFrame: Equatable {
    var id: String?
    var event: String
    var data: String
}

/// The text/event-stream format, line by line. Comment lines (the keepalives)
/// produce nothing, which is fine: the watchdog counts bytes, not frames.
struct SSEParser {
    private var id: String?
    private var event: String?
    private var data: [String] = []
    private var pending = Data()
    private(set) var lastEventID: String?
    private(set) var retry: Int?

    mutating func feed(line raw: String) -> SSEFrame? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if line.isEmpty {
            defer { id = nil; event = nil; data = [] }
            if let id { lastEventID = id }
            guard !data.isEmpty || event != nil else { return nil }
            return SSEFrame(id: id ?? lastEventID, event: event ?? "message", data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var rest = line[line.index(after: colon)...]
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            value = rest
        } else {
            field = Substring(line); value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        case "id": if !value.contains("\0") { id = String(value) }
        case "retry": retry = Int(value)
        default: break
        }
        return nil
    }

    /// Bytes as they come off the wire, possibly split mid-line.
    mutating func feed(_ chunk: Data) -> [SSEFrame] {
        pending.append(chunk)
        var frames: [SSEFrame] = []
        while let newline = pending.firstIndex(of: 10) {
            let lineData = pending[pending.startIndex..<newline]
            pending = Data(pending[pending.index(after: newline)...])
            if let frame = feed(line: String(decoding: lineData, as: UTF8.self)) { frames.append(frame) }
        }
        return frames
    }
}

// MARK: - durable history

/// `~/.pager/events.jsonl`: every ambient event, local and from hubs, one per
/// line, plus small `state` lines when one is dismissed or brought back. Rolls
/// to `.1` past four megabytes, like the panel log.
enum AmbientHistory {
    static var path: String { AmbientPaths.history }
    static var previous: String { path + ".1" }
    static var rotateBytes = 4 * 1024 * 1024

    static func append(_ event: AmbientEvent) {
        var event = event
        if event.receivedAt == nil { event.receivedAt = Date() }
        write(event.json)
    }

    /// `key` is the event's connection-qualified key (`AmbientEvent.key`).
    static func appendState(key: String, dismissedAt: Date?) {
        var object: [String: Any] = ["kind": "state", "key": key, "at": AmbientTime.string(Date())]
        object["dismissed_at"] = dismissedAt.map(AmbientTime.string) ?? NSNull()
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) { write(data) }
    }

    /// One `write` on an O_APPEND descriptor, so a daemon and a `pager event`
    /// writing at the same moment cannot interleave half lines.
    private static func write(_ data: Data) {
        AmbientPaths.ensure()
        rotate()
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var line = data
        line.append(10)
        _ = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
    }

    private static func rotate() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int,
              size > rotateBytes else { return }
        try? FileManager.default.removeItem(atPath: previous)
        try? FileManager.default.moveItem(atPath: path, toPath: previous)
    }

    /// Oldest first, one entry per id, dismissals applied.
    static func load(limit: Int = 5000) -> [AmbientEvent] {
        var order: [String] = []
        var events: [String: AmbientEvent] = [:]
        for file in [previous, path] {
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let data = Data(line.utf8)
                if line.contains("\"kind\":\"state\"") {
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let key = object["key"] as? String else { continue }
                    events[key]?.dismissedAt = (object["dismissed_at"] as? String).flatMap(AmbientTime.parse)
                    continue
                }
                guard let event = AmbientEvent.decode(data) else { continue }
                if events[event.key] == nil { order.append(event.key) }
                events[event.key] = event
            }
        }
        return order.suffix(limit).compactMap { events[$0] }
    }

    /// The same history shaped like panel log rows, so `pager log --window`
    /// can list both in one place.
    static func logRows(limit: Int = 5000) -> [[String: String]] {
        load(limit: limit).map { event in
            var row: [String: String] = [
                // A dot keeps these apart from the panel log's numeric ids.
                "id": "\u{00B7}" + (event.cursor ?? String(event.id.suffix(5))),
                "at": AmbientTime.string(event.happened ?? Date.distantPast),
                "event": "ambient",
                "level": logLevel(event.severity),
                "source": event.label,
                "title": plain(event.text),
                "event_id": event.id,
                "origin": event.origin ?? "local",
            ]
            if let connection = event.connection { row["connection"] = connection }
            if let type = event.type { row["type"] = type }
            if let subject = event.subject { row["subject"] = subject }
            if let detail = event.detail { row["detail"] = detail }
            if let url = event.url { row["url"] = url }
            if let dismissed = event.dismissedAt { row["dismissed"] = AmbientTime.string(dismissed) }
            return row
        }
    }

    static func logLevel(_ severity: String?) -> String {
        switch Severity(rawValue: severity ?? "info") {
        case .debug: return "debug"
        case .warn: return "warn"
        case .error, .critical: return "error"
        default: return "info"
        }
    }

    /// Markdown markers off, for places that show plain text.
    static func plain(_ text: String) -> String {
        if let attributed = try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return String(attributed.characters)
        }
        return text
    }
}

// MARK: - daemon state

/// `~/.pager/ambient-state.json`: what survives a restart. One cursor per
/// connection, local sticky lines, and enough of the last event for `--status`.
struct AmbientState: Codable, Equatable {
    var cursors: [String: String] = [:]
    var lastEventID: String?
    var lastEventAt: Date?
    var lastEventText: String?
    var lastEventSource: String?
    var stickies: [AmbientEvent] = []

    enum CodingKeys: String, CodingKey {
        case cursors, stickies
        case lastEventID = "last_event_id", lastEventAt = "last_event_at"
        case lastEventText = "last_event_text", lastEventSource = "last_event_source"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cursors = ((try? c.decodeIfPresent([String: String].self, forKey: .cursors)) ?? nil) ?? [:]
        lastEventID = try? c.decodeIfPresent(String.self, forKey: .lastEventID)
        lastEventAt = (try? c.decodeIfPresent(String.self, forKey: .lastEventAt)).flatMap { $0 }.flatMap(AmbientTime.parse)
        lastEventText = try? c.decodeIfPresent(String.self, forKey: .lastEventText)
        lastEventSource = try? c.decodeIfPresent(String.self, forKey: .lastEventSource)
        stickies = ((try? c.decodeIfPresent([AmbientEvent].self, forKey: .stickies)) ?? nil) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cursors, forKey: .cursors)
        try c.encodeIfPresent(lastEventID, forKey: .lastEventID)
        try c.encodeIfPresent(lastEventAt.map(AmbientTime.string), forKey: .lastEventAt)
        try c.encodeIfPresent(lastEventText, forKey: .lastEventText)
        try c.encodeIfPresent(lastEventSource, forKey: .lastEventSource)
        try c.encode(stickies, forKey: .stickies)
    }

    static func load(_ path: String = AmbientPaths.state) -> AmbientState {
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(AmbientState.self, from: data) else { return AmbientState() }
        return state
    }

    func save(_ path: String = AmbientPaths.state) {
        AmbientPaths.ensure()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(self) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}

// MARK: - the daemon's own log

/// Plain lines in `~/.pager/ambient.log`: connects, drops, dismissals. Kept
/// small, because a resident process that logs forever is a leak with extra steps.
enum AmbientLog {
    private static let lock = NSLock()

    static func write(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        AmbientPaths.ensure()
        let path = AmbientPaths.log
        if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_000_000 {
            try? FileManager.default.removeItem(atPath: path + ".1")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".1")
        }
        let line = "\(AmbientTime.string(Date())) \(message)\n"
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
        if ProcessInfo.processInfo.environment["PAGER_DEBUG"] != nil {
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}
