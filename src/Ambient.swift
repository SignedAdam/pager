import AppKit
import SwiftUI

// MARK: - ambient: the resident overlay
//
// `pager ambient` keeps one transparent, click-through panel in a corner of
// the screen and draws the stream into it: one line per event, text only by
// default, fading after its lifetime. The panel never becomes key, so it can
// never take a keystroke. Middle-click is read from a global mouse monitor and
// hit-tested against the rows, which is how a line can be dismissed without
// the overlay ever accepting a click.

struct AmbientLine: Identifiable, Equatable {
    /// `connection/id`, so two hubs can use the same event id.
    let id: String
    var event: AmbientEvent
    var look: ResolvedPresentation
    /// The source column: `work·deploys` when more than one hub is connected.
    var label: String
    var shownAt: Date
    var expires: Date?
    /// Effects run on lines that arrived as they happened, and on stickies.
    /// A catch-up after sleep comes back still.
    var animate: Bool

    var anchor: Date { event.receivedAt ?? event.occurredAt ?? shownAt }
}

@MainActor final class AmbientStore: ObservableObject {
    @Published var lines: [AmbientLine] = []
    @Published var settings: AmbientSettings {
        didSet { if settings != oldValue { settingsChanged(from: oldValue) } }
    }
    @Published var history: [AmbientEvent] = []
    @Published var paused = false
    /// Per connection id: `connected`, `reconnecting in 4s`, `no reader key`…
    @Published var phases: [String: String] = [:]
    @Published var keySources: [String: String] = [:]

    var state: AmbientState
    var rowFrames: [String: CGRect] = [:]
    var hubs: [String: HubClient] = [:]
    var geometryChanged: (() -> Void)?
    var demoFinished: (() -> Void)?
    /// Where `Demo burst` continues from, like the prototype's Next.
    var demoCursor = 0

    private var seen = Set<String>()
    private var ticker: Timer?
    private var demoTimer: Timer?
    private var settingsSave: DispatchWorkItem?
    private var stateSave: DispatchWorkItem?
    let historyLimit = 2000

    init(settings: AmbientSettings = AmbientSettings.load(), state: AmbientState = AmbientState.load()) {
        self.settings = settings
        self.state = state
        history = Array(AmbientHistory.load(limit: historyLimit).reversed())
        seen = Set(history.map(\.key))
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    var activeConnections: [AmbientConnection] {
        AmbientCredentials.connections(settings).filter(\.enabled)
    }

    func connectionName(_ id: String?) -> String? {
        guard let id else { return nil }
        return AmbientCredentials.connections(settings).first(where: { $0.id == id })?.name ?? id
    }

    func label(for event: AmbientEvent) -> String {
        guard event.fromHub, activeConnections.count > 1, let name = connectionName(event.connection) else { return event.label }
        return name + "\u{00B7}" + event.label
    }

    // MARK: arriving

    /// Every event comes through here: hubs, `pager event`, the demo.
    func ingest(_ incoming: AmbientEvent, record: Bool = true) {
        var event = incoming
        if event.receivedAt == nil { event.receivedAt = Date() }
        if seen.contains(event.key) {
            // Seen before: a replay or a sticky restore. Keep what we already
            // know about it, so a line dismissed here stays dismissed.
            if let index = history.firstIndex(where: { $0.key == event.key }) {
                if event.dismissedAt == nil { event.dismissedAt = history[index].dismissedAt }
                history[index] = event
            }
        } else {
            seen.insert(event.key)
            if record && event.origin != "demo" { AmbientHistory.append(event) }
            history.insert(event, at: 0)
            if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
            if event.origin != "demo" {
                state.lastEventID = event.key
                state.lastEventAt = event.receivedAt
                state.lastEventText = AmbientHistory.plain(event.text)
                state.lastEventSource = label(for: event)
            }
            AmbientLog.write("event \(event.key) source \(event.source)" + (event.cursor.map { " cursor \($0)" } ?? ""))
        }
        scheduleStateSave()
        present(event)
    }

    /// Put a line on screen if it belongs there. `again` is the history
    /// window's Show again: now, fresh, whatever its age or state.
    func present(_ event: AmbientEvent, again: Bool = false) {
        guard again || !paused else { return }
        let look = AmbientRules.resolve(event, settings)
        let now = Date()
        var decision = AmbientRules.decide(event, look, now: now)
        if again {
            let expires: Date? = { if case .seconds(let s) = look.lifetime { return now.addingTimeInterval(s) }; return nil }()
            decision = AmbientRules.Decision(show: true, expires: expires, fresh: true)
        }
        guard decision.show else { return }
        if let index = lines.firstIndex(where: { $0.id == event.key }) {
            guard again else { lines[index].event = event; return }
            lines.remove(at: index)
        }
        let line = AmbientLine(id: event.key, event: event, look: look, label: label(for: event), shownAt: now,
                               expires: decision.expires, animate: decision.fresh || look.lifetime.isSticky)
        if decision.fresh {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) { lines.insert(line, at: 0) }
        } else {
            // A catch-up line goes where its time puts it, without a fuss.
            let index = lines.firstIndex(where: { $0.anchor < line.anchor }) ?? lines.count
            lines.insert(line, at: index)
        }
        enforceLimit()
        if look.lifetime.isSticky, event.origin == "local", !state.stickies.contains(where: { $0.key == event.key }) {
            state.stickies.append(event)
            scheduleStateSave()
        }
    }

    /// Too many lines: the oldest that will go anyway go first. Stickies stay.
    private func enforceLimit() {
        var overflow = lines.count - settings.maxLines
        guard overflow > 0 else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            var index = lines.count - 1
            while overflow > 0 && index >= 0 {
                if lines[index].expires != nil { lines.remove(at: index); overflow -= 1 }
                index -= 1
            }
        }
    }

    private func tick() {
        let now = Date()
        guard lines.contains(where: { ($0.expires ?? .distantFuture) <= now }) else { return }
        withAnimation(.easeOut(duration: 0.65)) { lines.removeAll { ($0.expires ?? .distantFuture) <= now } }
        if lines.isEmpty, demoTimer == nil { demoFinished?() }
    }

    // MARK: dismissing

    private func event(forKey key: String) -> AmbientEvent? {
        history.first(where: { $0.key == key }) ?? lines.first(where: { $0.id == key })?.event
    }

    /// Middle-click, the history window, or `pager ambient` over the socket.
    func dismiss(_ key: String) {
        withAnimation(.easeOut(duration: 0.35)) { lines.removeAll { $0.id == key } }
        setDismissed(key, Date(), propagate: true)
    }

    /// Local bookkeeping for a dismissal from anywhere, and the call to the
    /// hub when it started here. Dismissal on a hub is per reader: it hides
    /// the line for this key's owner, not for anyone else reading that hub.
    func setDismissed(_ key: String, _ date: Date?, propagate: Bool) {
        let event = event(forKey: key)
        if let index = history.firstIndex(where: { $0.key == key }) {
            if (history[index].dismissedAt == nil) == (date == nil) && !propagate { return }
            history[index].dismissedAt = date
        }
        if event?.origin != "demo" { AmbientHistory.appendState(key: key, dismissedAt: date) }
        if date != nil, state.stickies.contains(where: { $0.key == key }) {
            state.stickies.removeAll { $0.key == key }
            scheduleStateSave()
        }
        AmbientLog.write("\(date == nil ? "undismissed" : "dismissed") \(key)\(propagate ? "" : " (from hub)")")
        if propagate, let event, event.fromHub, let connection = event.connection {
            hubs[connection]?.setDismissed(event.id, date != nil)
        }
    }

    func undismiss(_ key: String) {
        setDismissed(key, nil, propagate: true)
        if var event = event(forKey: key) {
            event.dismissedAt = nil
            if AmbientRules.resolve(event, settings).lifetime.isSticky {
                if event.origin == "local" && !state.stickies.contains(where: { $0.key == key }) {
                    state.stickies.append(event); scheduleStateSave()
                }
                present(event, again: true)
            }
        }
    }

    /// A `state` frame: this reader dismissed or restored it somewhere else.
    func applyRemoteState(connection: String, id: String, dismissedAt: Date?) {
        let key = connection + "/" + id
        if dismissedAt != nil {
            withAnimation(.easeOut(duration: 0.35)) { lines.removeAll { $0.id == key } }
        }
        setDismissed(key, dismissedAt, propagate: false)
        if dismissedAt == nil, var event = event(forKey: key) {
            event.dismissedAt = nil
            if AmbientRules.resolve(event, settings).lifetime.isSticky { present(event) }
        }
    }

    /// A hub's list of open stickies, on start and after every reconnect.
    func restoreStickies(connection: String, _ open: [AmbientEvent]) {
        let keys = Set(open.map(\.key))
        for event in open {
            // Dismissed here while the hub was out of reach: tell it now.
            if history.first(where: { $0.key == event.key })?.dismissedAt != nil {
                hubs[connection]?.setDismissed(event.id, true)
            }
            ingest(event)
        }
        let gone = lines.filter {
            $0.event.connection == connection && $0.event.fromHub && $0.look.lifetime.isSticky && !keys.contains($0.id)
        }
        for line in gone {
            withAnimation(.easeOut(duration: 0.35)) { lines.removeAll { $0.id == line.id } }
            setDismissed(line.id, Date(), propagate: false)
        }
    }

    /// Local stickies: the ones the overlay saw, plus any `pager event` wrote
    /// to history while nothing was running.
    func restoreLocalStickies() {
        var keys = Set<String>()
        let fromHistory = history.reversed().filter {
            $0.origin == "local" && $0.dismissedAt == nil && AmbientRules.resolve($0, settings).lifetime.isSticky
        }
        for event in state.stickies + fromHistory where event.dismissedAt == nil && keys.insert(event.key).inserted {
            present(event)
        }
    }

    func clear() { withAnimation(.easeOut(duration: 0.4)) { lines.removeAll() } }

    // MARK: demo

    func playDemo(count: Int, interval: TimeInterval) {
        let samples = AmbientDemo.events()
        guard !samples.isEmpty, count > 0 else { return }
        var remaining = count
        demoTimer?.invalidate()
        let step = { [weak self] in
            guard let self else { return }
            var event = samples[self.demoCursor % samples.count]
            self.demoCursor += 1
            event.id = "demo_\(self.demoCursor)_\(Int(Date().timeIntervalSince1970))"
            event.receivedAt = Date(); event.occurredAt = Date()
            self.ingest(event, record: false)
            remaining -= 1
        }
        step()
        guard remaining > 0 else { return }
        demoTimer = Timer.scheduledTimer(withTimeInterval: max(0.05, interval), repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { timer.invalidate(); return }
                step()
                if remaining <= 0 { timer.invalidate(); self.demoTimer = nil }
            }
        }
    }

    // MARK: hubs

    /// One client per enabled connection. Restarted whenever connections change.
    func startHubs() {
        for client in hubs.values { client.stop() }
        hubs = [:]
        phases = [:]
        keySources = [:]
        let all = AmbientCredentials.connections(settings)
        for connection in all where connection.enabled {
            guard let base = connection.base else {
                phases[connection.id] = "bad URL"; continue
            }
            guard let (key, from) = AmbientCredentials.readKey(connection, total: all.count) else {
                phases[connection.id] = "no reader key"
                AmbientLog.write("hub \(connection.id): no reader key (Keychain, key file or PAGER_AMBIENT_KEY)")
                continue
            }
            keySources[connection.id] = from
            let client = HubClient(connection: connection, base: base, key: key)
            client.cursor = state.cursors[connection.id]
            let id = connection.id
            client.onEvent = { [weak self] in self?.ingest($0) }
            client.onState = { [weak self] in self?.applyRemoteState(connection: id, id: $0, dismissedAt: $1) }
            client.onStickies = { [weak self] in self?.restoreStickies(connection: id, $0) }
            client.onPhase = { [weak self] phase in self?.phases[id] = phase.label }
            // Only stream frames move the cursor. A sticky restored from the
            // list is old and would otherwise wind it back.
            client.onCursor = { [weak self] cursor in
                self?.state.cursors[id] = cursor
                self?.scheduleStateSave()
            }
            hubs[id] = client
            AmbientLog.write("hub \(id): starting, \(base.absoluteString), key from \(from), cursor \(client.cursor ?? "none")")
            client.start()
        }
    }

    func reconnectAll() { for client in hubs.values { client.reconnectNow() } }

    // MARK: persistence

    private func settingsChanged(from old: AmbientSettings) {
        settingsSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.settingsSave = nil
            self?.settings.save()
        }
        settingsSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        geometryChanged?()
        if old.connections != settings.connections { startHubs() }
    }

    func scheduleStateSave() {
        guard stateSave == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.stateSave = nil
            self?.state.save()
        }
        stateSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func saveNow() {
        stateSave?.cancel(); stateSave = nil
        state.save()
        if settingsSave != nil { settingsSave?.cancel(); settingsSave = nil; settings.save() }
    }

    var knownSources: [String] {
        Array(Set(history.map(\.source)).union(settings.sources.keys)).sorted()
    }

    func status() -> [String: Any] {
        let connections: [[String: Any]] = AmbientCredentials.connections(settings).map { c in
            ["id": c.id, "name": c.name, "url": c.url, "enabled": c.enabled,
             "phase": phases[c.id] ?? (c.enabled ? "idle" : "disabled"),
             "cursor": state.cursors[c.id] ?? "", "key_source": keySources[c.id] ?? "none",
             "gaps": hubs[c.id]?.gaps ?? 0]
        }
        var out: [String: Any] = [
            "running": true, "pid": Int(getpid()), "paused": paused, "connections": connections,
            "visible": lines.count, "visible_ids": lines.map(\.id), "history": history.count,
        ]
        if let at = state.lastEventAt { out["last_event_at"] = AmbientTime.string(at) }
        if let text = state.lastEventText { out["last_event"] = text }
        if let source = state.lastEventSource { out["last_source"] = source }
        return out
    }
}

// MARK: - the overlay views

private struct AmbientRowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

struct AmbientOverlay: View {
    @ObservedObject var store: AmbientStore

    var body: some View {
        let s = store.settings
        let top = s.corner.hasPrefix("top"), right = s.corner.hasSuffix("right")
        let ordered = top ? store.lines : Array(store.lines.reversed())
        VStack(alignment: right ? .trailing : .leading, spacing: s.rowGap) {
            ForEach(ordered) { line in
                AmbientRow(line: line, settings: s, right: right)
                    .padding(.vertical, s.rowPadding)
                    .padding(.horizontal, s.sidePadding)
                    .frame(width: s.width, alignment: right ? .trailing : .leading)
                    .background(
                        RoundedRectangle(cornerRadius: s.cards ? 10 : 4)
                            .fill(Color.black.opacity(s.backdrop ? 0.65 : 0)))
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: AmbientRowFrames.self,
                                               value: [line.id: geometry.frame(in: .named("ambient"))])
                    })
                    .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: top ? (right ? .topTrailing : .topLeading) : (right ? .bottomTrailing : .bottomLeading))
        .coordinateSpace(name: "ambient")
        .onPreferenceChange(AmbientRowFrames.self) { frames in
            Task { @MainActor in store.rowFrames = frames }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct AmbientRow: View {
    let line: AmbientLine
    let settings: AmbientSettings
    var right = true

    private var accent: Color { Color(hex: line.look.accent) ?? .white }
    private var sourceTint: Color { Color(hex: line.look.sourceColor)?.opacity(0.75) ?? .white.opacity(0.4) }

    var body: some View {
        if settings.cards { card } else { plain }
    }

    private var message: some View {
        let e = line.event, look = line.look
        let context = (look.layout == .inline ? line.label + " \u{00B7} " : "") + (e.subject.map { $0 + "  " } ?? "")
        return StyledMessage(text: e.text, context: context, color: accent, fontSize: settings.fontSize,
                             effect: line.animate ? look.effect : .none, target: look.target, period: look.period,
                             startedAt: line.shownAt, lineLimit: look.lines)
    }

    private var plain: some View {
        HStack(alignment: .firstTextBaseline, spacing: settings.columnGap) {
            if settings.icons {
                Image(systemName: AmbientRow.symbol(line.event)).foregroundColor(accent.opacity(0.7))
            }
            if line.look.layout == .split {
                Text(line.label)
                    .foregroundColor(sourceTint)
                    .lineLimit(1)
                    .frame(width: settings.sourceWidth, alignment: .leading)
            }
            message.frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
            if settings.ages { AmbientAge(since: line.event.happened ?? line.shownAt, fontSize: settings.fontSize) }
        }
        .font(.system(size: settings.fontSize))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 10) {
            if settings.icons {
                Image(systemName: AmbientRow.symbol(line.event))
                    .font(.system(size: settings.fontSize, weight: .medium))
                    .foregroundColor(accent).frame(width: 18).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.label.uppercased())
                        .font(.system(size: max(9, settings.fontSize - 3), weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: line.look.sourceColor) ?? accent)
                    if let subject = line.event.subject {
                        Text(subject).font(.system(size: max(10, settings.fontSize - 2)))
                            .foregroundColor(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if settings.ages { AmbientAge(since: line.event.happened ?? line.shownAt, fontSize: settings.fontSize) }
                }
                StyledMessage(text: line.event.text, color: accent, fontSize: settings.fontSize,
                              effect: line.animate ? line.look.effect : .none, target: line.look.target,
                              period: line.look.period, startedAt: line.shownAt, lineLimit: max(3, line.look.lines))
                if settings.details, let detail = line.event.detail {
                    Text(AmbientHistory.plain(detail)).font(.system(size: max(10, settings.fontSize - 1)))
                        .foregroundColor(.white.opacity(0.5)).lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func symbol(_ event: AmbientEvent) -> String {
        switch (event.type ?? "").lowercased() {
        case "push": return "arrow.up.right"
        case "pr", "pr.opened": return "arrow.triangle.branch"
        case "merge", "pr.merged": return "arrow.triangle.merge"
        case "deploy": return "shippingbox"
        case "failure", "error", "failed": return "xmark.circle"
        case "down": return "network.slash"
        case "warning": return "exclamationmark.triangle"
        case "sale", "payment": return "creditcard"
        case "recovery", "success", "up", "backup": return "checkmark.circle"
        default: return "sparkle"
        }
    }
}

/// `now`, `12s`, `4m`, `3h`, `2d`, ticking once a second on its own.
struct AmbientAge: View {
    let since: Date
    let fontSize: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(AmbientTime.age(context.date.timeIntervalSince(since)))
                .font(.system(size: max(9, fontSize - 2)).monospacedDigit())
                .foregroundColor(.white.opacity(0.3))
                .lineLimit(1)
                .frame(minWidth: max(18, fontSize * 1.8), alignment: .trailing)
        }
    }
}

// MARK: - the app

final class AmbientPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AmbientApp: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    enum Mode { case daemon, demo(count: Int, interval: TimeInterval) }

    let store: AmbientStore
    let mode: Mode
    private var panel: AmbientPanel!
    private var statusItem: NSStatusItem?
    private var server: AmbientSocket.Server?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var monitors: [Any] = []
    private var signals: [DispatchSourceSignal] = []
    private var pauseItem: NSMenuItem?
    private var statusLine: NSMenuItem?

    init(mode: Mode) {
        self.mode = mode
        store = AmbientStore()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = AmbientPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.contentView = NSHostingView(rootView: AmbientOverlay(store: store))
        store.geometryChanged = { [weak self] in self?.positionOverlay() }
        positionOverlay()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(positionOverlay),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        watchMiddleClicks()
        handleSignals()

        switch mode {
        case .daemon:
            buildMenu()
            startSocket()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                              name: NSWorkspace.didWakeNotification, object: nil)
            store.restoreLocalStickies()
            store.startHubs()
            AmbientLog.write("ambient started, pid \(getpid())")
        case .demo(let count, let interval):
            store.demoFinished = { NSApp.terminate(nil) }
            store.playDemo(count: count, interval: interval)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        for client in store.hubs.values { client.stop() }
        store.saveNow()
        server?.stop()
        if case .daemon = mode { AmbientLog.write("ambient stopped") }
    }

    @objc private func didWake() {
        AmbientLog.write("woke from sleep, reconnecting")
        store.reconnectAll()
    }

    @objc func positionOverlay() {
        let screens = NSScreen.screens
        guard let screen = store.settings.screen < screens.count ? screens[store.settings.screen] : screens.first
        else { return }
        let frame = screen.visibleFrame
        let width = min(store.settings.width + 24, frame.width)
        let x = store.settings.corner.hasSuffix("left") ? frame.minX + 12 : frame.maxX - width - 12
        panel.setFrame(NSRect(x: x, y: frame.minY + 6, width: width, height: max(0, frame.height - 12)), display: true)
    }

    // MARK: middle click

    private func watchMiddleClicks() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.buttonNumber == 2 else { return }
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.middleClick(at: location) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { event in
            handler(event); return event
        }) {
            monitors.append(local)
        }
    }

    private func middleClick(at point: NSPoint) {
        guard store.settings.middleClick, let panel, panel.frame.contains(point) else { return }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let slack = store.settings.rowGap / 2
        guard let hit = store.rowFrames.first(where: { _, frame in
            frame.insetBy(dx: 0, dy: -slack).contains(local)
        }), store.lines.contains(where: { $0.id == hit.key }) else { return }
        store.dismiss(hit.key)
    }

    // MARK: signals and socket

    private func handleSignals() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    private func startSocket() {
        let server = AmbientSocket.Server { [weak self] request in
            let done = DispatchSemaphore(value: 0)
            var reply: [String: Any] = ["ok": false, "error": "gone"]
            Task { @MainActor in
                reply = self?.handle(request) ?? reply
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2.5)
            return reply
        }
        do {
            try server.start()
            self.server = server
        } catch {
            AmbientLog.write("socket: \(error)")
            FileHandle.standardError.write(Data("pager ambient: \(error)\n".utf8))
        }
    }

    /// The whole local protocol. Nothing in it runs a command.
    private func handle(_ request: [String: Any]) -> [String: Any] {
        switch request["op"] as? String ?? "" {
        case "ping", "status":
            return store.status().merging(["ok": true], uniquingKeysWith: { $1 })
        case "event":
            guard let object = request["event"],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  var event = AmbientEvent.decode(data) else { return ["ok": false, "error": "unreadable event"] }
            event.origin = "local"
            store.ingest(event)
            return ["ok": true, "id": event.id, "shown": store.lines.contains(where: { $0.id == event.id })]
        case "dismiss":
            guard let key = (request["key"] as? String)
                    ?? (request["id"] as? String).map({ $0.contains("/") ? $0 : "local/" + $0 })
            else { return ["ok": false, "error": "no key"] }
            store.dismiss(key)
            return ["ok": true]
        case "demo":
            store.playDemo(count: request["count"] as? Int ?? 50, interval: request["interval"] as? Double ?? 2)
            return ["ok": true]
        case "pause":
            store.paused = (request["paused"] as? Bool) ?? !store.paused
            return ["ok": true, "paused": store.paused]
        case "clear":
            store.clear()
            return ["ok": true]
        case "settings":
            showSettings()
            return ["ok": true]
        case "history":
            showHistory()
            return ["ok": true]
        case "reload":
            store.settings = AmbientSettings.load()
            store.startHubs()
            return ["ok": true]
        case "quit":
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { NSApp.terminate(nil) }
            return ["ok": true]
        default:
            return ["ok": false, "error": "unknown op"]
        }
    }

    // MARK: menu bar

    private func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "pager ambient")
        let menu = NSMenu()
        menu.delegate = self
        let line = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        line.isEnabled = false
        statusLine = line
        menu.addItem(line)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: "Pause stream", action: #selector(togglePause), keyEquivalent: "")
        pauseItem = pause
        for entry in [pause,
                      NSMenuItem(title: "Clear screen", action: #selector(clearScreen), keyEquivalent: ""),
                      NSMenuItem.separator(),
                      NSMenuItem(title: "History\u{2026}", action: #selector(showHistory), keyEquivalent: ""),
                      NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ""),
                      NSMenuItem(title: "Demo burst", action: #selector(demoBurst), keyEquivalent: ""),
                      NSMenuItem.separator(),
                      NSMenuItem(title: "Quit ambient", action: #selector(quit), keyEquivalent: "")] {
            entry.target = self
            menu.addItem(entry)
        }
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem?.title = store.paused ? "Resume stream" : "Pause stream"
        let phases = store.activeConnections.map { "\($0.name): \(store.phases[$0.id] ?? "idle")" }
        statusLine?.title = phases.isEmpty ? "Local only" : phases.joined(separator: "  \u{00B7}  ")
    }

    @objc private func togglePause() { store.paused.toggle() }
    @objc private func clearScreen() { store.clear() }
    @objc private func demoBurst() { store.playDemo(count: 6, interval: 0.35) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window(title: "Ambient settings", size: NSSize(width: 380, height: 560),
                                    view: AmbientSettingsView(store: store))
        }
        bringForward(settingsWindow)
    }

    @objc func showHistory() {
        if historyWindow == nil {
            historyWindow = window(title: "Ambient history", size: NSSize(width: 560, height: 620),
                                   view: AmbientHistoryView(store: store))
        }
        bringForward(historyWindow)
    }

    private func window<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return window
    }

    private func bringForward(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
