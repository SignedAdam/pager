import AppKit
import Carbon.HIToolbox
import Combine
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
    /// When a timed pause ends. Nil with `paused` set means until resumed.
    @Published var pausedUntil: Date?
    /// Per connection id: `connected`, `reconnecting in 4s`, `no reader key`…
    @Published var phases: [String: String] = [:]
    @Published var keySources: [String: String] = [:]

    var state: AmbientState
    var rowFrames: [String: CGRect] = [:]
    var hubs: [String: HubClient] = [:]
    var geometryChanged: (() -> Void)?
    var shortcutsChanged: (() -> Void)?
    /// The line under the pointer, which shows its close button.
    @Published var hovered: String?
    var hoverChanged: (() -> Void)?
    var demoFinished: (() -> Void)?
    /// Where `Demo burst` continues from, like the prototype's Next.
    var demoCursor = 0

    private var seen = Set<String>()
    private var ticker: Timer?
    private var demoTimer: Timer?
    private var settingsSave: DispatchWorkItem?
    private var stateSave: DispatchWorkItem?
    let historyLimit = 2000

    init(settings: AmbientSettings = AmbientSettings.load(), state: AmbientState = AmbientState.load(),
         loadHistory: Bool = true) {
        self.settings = settings
        self.state = state
        history = loadHistory ? Array(AmbientHistory.load(limit: historyLimit).reversed()) : []
        seen = Set(history.map(\.key))
        if let until = state.pausedUntil, until > Date() {
            paused = true
            // "Until resumed" is stored as the far future, shown as no time at all.
            pausedUntil = until > Date().addingTimeInterval(400 * 86_400) ? nil : until
        }
        // In the common modes, so lines still leave while a menu is open; and
        // with App Nap off, which would otherwise stretch this timer to minutes
        // when nothing else is happening and leave lines up long past their time.
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        ticker.tolerance = 0.1
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        awake = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                      reason: "ambient lines expire on time")
    }

    private var awake: NSObjectProtocol?

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
            // First sight only, so a replay or a restart never raises it twice.
            if event.fromHub, let request = event.panel { raisePanel(event, request) }
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

    // MARK: panels

    private var panelTimes: [Date] = []
    private var panelsHeld = 0
    /// At most this many panels a minute from hubs; the rest wait in history
    /// and one panel says how many, so a storm or a long sleep is one ping.
    static let panelBurst = 3

    /// `data.panel` on a hub event: the full pager panel, as a child process of
    /// this binary with plain arguments (no shell). Pause quiets the stream,
    /// not panels; muting the source or turning panels off stops them.
    func raisePanel(_ event: AmbientEvent, _ request: AmbientPanelRequest) {
        guard settings.panels, settings.sources[event.source]?.mute != true, event.dismissedAt == nil else {
            AmbientLog.write("panel \(event.key) skipped (panels off or source muted)")
            return
        }
        let now = Date()
        panelTimes.removeAll { now.timeIntervalSince($0) > 60 }
        guard panelTimes.count < Self.panelBurst else {
            panelsHeld += 1
            if panelsHeld == 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in self?.flushHeldPanels() }
            }
            AmbientLog.write("panel \(event.key) held (\(panelsHeld) waiting)")
            return
        }
        panelTimes.append(now)
        launchPanel(AmbientPanelRequest.arguments(event, request, label: label(for: event)), key: event.key)
    }

    private func flushHeldPanels() {
        let held = panelsHeld
        panelsHeld = 0
        guard held > 0 else { return }
        launchPanel(["--title", "\(held) more panel\(held == 1 ? "" : "s") from your hubs",
                     "--source", "ambient",
                     "--body", "They arrived together, so they were held back. Every one of them is in the ambient history.",
                     "--sound", "bell", "--pinned",
                     "--action", "History:'" + AmbientCommands.binary.replacingOccurrences(of: "'", with: "'\\''") + "' ambient --history"],
                    key: "held")
    }

    private func launchPanel(_ arguments: [String], key: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: AmbientCommands.binary)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            AmbientLog.write("panel \(key) raised (pid \(task.processIdentifier))")
        } catch {
            AmbientLog.write("panel \(key) failed to start: \(error)")
        }
    }

    /// Too many lines: the oldest that will go anyway go first. Stickies stay.
    private func enforceLimit() {
        var overflow = lines.count - settings.maxLines
        guard overflow > 0 else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            var index = lines.count - 1
            while overflow > 0 && index >= 0 {
                if !lines[index].look.lifetime.isSticky { lines.remove(at: index); overflow -= 1 }
                index -= 1
            }
        }
    }

    private func tick() {
        let now = Date()
        if paused, let until = pausedUntil, until <= now { resume() }
        guard lines.contains(where: { ($0.expires ?? .distantFuture) <= now }) else { return }
        withAnimation(.easeOut(duration: 0.65)) { lines.removeAll { ($0.expires ?? .distantFuture) <= now } }
        if let hovered, !lines.contains(where: { $0.id == hovered }) { hoverChanged?() }
        if lines.isEmpty, demoTimer == nil { demoFinished?() }
    }

    // MARK: dismissing

    private func event(forKey key: String) -> AmbientEvent? {
        history.first(where: { $0.key == key }) ?? lines.first(where: { $0.id == key })?.event
    }

    /// ⌃⌥⌫, the menu bar panel, or `pager ambient --dismiss newest`.
    func dismissNewest() {
        guard let newest = lines.first else { return }
        dismiss(newest.id)
    }

    /// ⌃⌥⇧⌫ or `--dismiss all`: every line on screen, stickies included.
    func dismissAll() {
        for line in lines { dismiss(line.id) }
    }

    /// Middle-click, the history window, or `pager ambient` over the socket.
    func dismiss(_ key: String) {
        withAnimation(.easeOut(duration: 0.35)) { lines.removeAll { $0.id == key } }
        if hovered == key { hovered = nil; hoverChanged?() }
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

    // MARK: pause

    /// Quiet for a while: the screen clears, events still go to history.
    func pause(until: Date?) {
        paused = true
        pausedUntil = until
        state.pausedUntil = until ?? .distantFuture
        scheduleStateSave()
        clear()
        AmbientLog.write("paused" + (until.map { " until \(AmbientTime.string($0))" } ?? ""))
    }

    /// Back on, without a flood: only what is still inside its lifetime (and
    /// open stickies) returns, quietly, the same rule as after sleep.
    func resume() {
        guard paused else { return }
        paused = false
        pausedUntil = nil
        state.pausedUntil = nil
        scheduleStateSave()
        for event in history.reversed() where event.dismissedAt == nil { present(event) }
        AmbientLog.write("resumed")
    }


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
                if case .needsApproval = AmbientKeychain.read(connection.id) {
                    phases[connection.id] = "Keychain needs approval"
                    AmbientLog.write("hub \(connection.id): the Keychain wants approval for this build; run "
                                     + "`pager ambient connect` again, or point it at a key file")
                    continue
                }
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
        if old.shortcuts != settings.shortcuts { shortcutsChanged?() }
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
            "running": true, "pid": Int(getpid()), "paused": paused,
            "paused_until": pausedUntil.map(AmbientTime.string) ?? "", "connections": connections,
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
    var blur = true

    static let clearKey = "__clear_all"

    /// Under the last line while any line is pointed at: close them all.
    private var clearAll: some View {
        AmbientClearAll(fontSize: store.settings.fontSize) { store.dismissAll() }
            .background(GeometryReader { geometry in
                Color.clear.preference(key: AmbientRowFrames.self,
                                       value: [AmbientOverlay.clearKey: geometry.frame(in: .named("ambient"))])
            })
            .transition(.opacity)
    }

    var body: some View {
        let s = store.settings
        let top = s.corner.hasPrefix("top"), right = s.corner.hasSuffix("right")
        let ordered = top ? store.lines : Array(store.lines.reversed())
        let corner: Alignment = top ? (right ? .topTrailing : .topLeading) : (right ? .bottomTrailing : .bottomLeading)
        VStack(alignment: right ? .trailing : .leading, spacing: s.rowGap) {
            if !top, store.hovered != nil, store.lines.count > 1 { clearAll }
            ForEach(ordered) { line in
                AmbientRow(line: line, settings: s, right: right, hovered: store.hovered == line.id) {
                    store.dismiss(line.id)
                }
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
            if top, store.hovered != nil, store.lines.count > 1 { clearAll }
        }
        .animation(.easeOut(duration: 0.15), value: store.hovered != nil)
        .background(AmbientShade(strength: s.shade, visible: !store.lines.isEmpty && !s.backdrop, corner: corner, blur: blur))
        // The panel reaches the screen edge; the stack sits 12 pt in from it as
        // before, with room on the open sides for the shade to fade out.
        .padding(top ? .top : .bottom, 12)
        .padding(right ? .trailing : .leading, 12)
        .padding(top ? .bottom : .top, AmbientShadeGeometry.margin)
        .padding(right ? .leading : .trailing, AmbientShadeGeometry.margin)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: corner)
        .coordinateSpace(name: "ambient")
        .onPreferenceChange(AmbientRowFrames.self) { frames in
            Task { @MainActor in store.rowFrames = frames }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The shade: frosted dark glass behind the lines that fades to nothing at
/// its edges. The blur turns whatever is underneath (a page of text, a photo)
/// into a soft tone, so the lines never fight another layer of text; the tint
/// darkens it toward the screen corner. Grows with the stream, gone when empty.
enum AmbientShadeGeometry {
    /// How far the shade reaches past the text, and the feather inside that reach.
    static let reach: CGFloat = 72
    /// The visible shape sits `inset` inside the reach and is blurred by
    /// `feather`, so the fade is all but zero before the view's own edge.
    static let inset: CGFloat = 46
    static let feather: CGFloat = 20
    /// Room the panel keeps around the stack so the shade is never cut.
    static let margin: CGFloat = reach + 8
}

struct AmbientBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct AmbientShade: View {
    let strength: Double
    let visible: Bool
    let corner: Alignment
    /// Snapshots cannot see the window server's blur; they draw the tint only.
    var blur = true

    var body: some View {
        let toward: UnitPoint = corner == .topTrailing || corner == .bottomTrailing ? .trailing : .leading
        let away: UnitPoint = toward == .trailing ? .leading : .trailing
        ZStack {
            if blur {
                AmbientBlur().opacity(min(1, strength * 1.4))
            }
            LinearGradient(colors: [.black.opacity(0.45 * strength), .black.opacity(0.75 * strength)],
                           startPoint: away, endPoint: toward)
        }
        .mask(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .padding(AmbientShadeGeometry.inset)
                .blur(radius: AmbientShadeGeometry.feather))
        .padding(-AmbientShadeGeometry.reach)
        .opacity(visible && strength > 0 ? 1 : 0)
        .animation(.easeOut(duration: 0.6), value: visible)
        .allowsHitTesting(false)
    }
}

/// A tight dark edge on every glyph and a wider soft one, the way subtitles
/// stay readable over any picture. Applied to text only, never to a box.
struct AmbientHalo: ViewModifier {
    let strength: Double

    func body(content: Content) -> some View {
        if strength <= 0 {
            content
        } else {
            content
                .shadow(color: .black.opacity(0.55 * strength), radius: 0.5)
        }
    }
}

struct AmbientRow: View {
    let line: AmbientLine
    let settings: AmbientSettings
    var right = true
    var hovered = false
    var dismiss: () -> Void = {}

    private var accent: Color { Color(hex: line.look.accent) ?? .white }
    private var sourceTint: Color { Color(hex: line.look.sourceColor)?.opacity(0.85) ?? .white.opacity(0.5) }

    @ViewBuilder private var mark: some View {
        if settings.sourceIcons, let brand = line.look.brand {
            AmbientMark(brand: brand, color: Color(hex: line.look.sourceColor) ?? .white.opacity(0.7),
                        size: settings.fontSize)
        }
    }

    var body: some View {
        Group { if settings.cards { card } else { plain } }
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(hovered ? 0.07 : 0)).padding(-3))
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// The age, which turns into the close button while the line is pointed at.
    private var tail: some View {
        AmbientTail(since: line.event.happened ?? line.shownAt, fontSize: settings.fontSize,
                    showAge: settings.ages, hovered: hovered, dismiss: dismiss)
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
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    mark
                    Text(line.label).foregroundColor(sourceTint).lineLimit(1)
                }
                .frame(width: settings.sourceWidth, alignment: .leading)
            } else {
                mark
            }
            message.frame(maxWidth: .infinity, alignment: right ? .trailing : .leading)
            tail
        }
        .font(.system(size: settings.fontSize))
        .modifier(AmbientHalo(strength: settings.backdrop ? 0 : settings.shade))
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
                    mark
                    Text(line.label.uppercased())
                        .font(.system(size: max(9, settings.fontSize - 3), weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: line.look.sourceColor) ?? accent)
                    if let subject = line.event.subject {
                        Text(subject).font(.system(size: max(10, settings.fontSize - 2)))
                            .foregroundColor(.white.opacity(0.5)).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    tail
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
        .modifier(AmbientHalo(strength: settings.backdrop ? 0 : settings.shade))
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
struct AmbientClearAll: View {
    let fontSize: Double
    let action: () -> Void
    @State private var onButton = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "xmark").font(.system(size: max(8, fontSize - 3), weight: .semibold))
                Text("Clear all").font(.system(size: max(10, fontSize - 1), weight: .medium))
            }
            .foregroundColor(.white.opacity(onButton ? 1 : 0.6))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white.opacity(onButton ? 0.16 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { onButton = $0 }
        .animation(.easeOut(duration: 0.12), value: onButton)
        .padding(.top, 3)
    }
}

/// The end of a line: its age, or, while the line is pointed at, an × in the
/// same place. Pointing at the × itself lifts it onto a soft lit chip.
struct AmbientTail: View {
    let since: Date
    let fontSize: Double
    let showAge: Bool
    let hovered: Bool
    let dismiss: () -> Void
    @State private var onButton = false

    var body: some View {
        let width = max(22, fontSize * 2)
        ZStack(alignment: .trailing) {
            if showAge {
                AmbientAge(since: since, fontSize: fontSize).opacity(hovered ? 0 : 1)
            }
            if hovered {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: max(8, fontSize - 3), weight: onButton ? .bold : .semibold))
                        .foregroundColor(.white.opacity(onButton ? 1 : 0.6))
                        .frame(width: width, height: fontSize + 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(onButton ? 0.18 : 0))
                                .shadow(color: .white.opacity(onButton ? 0.25 : 0), radius: 4))
                        .scaleEffect(onButton ? 1.06 : 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .onHover { onButton = $0 }
                .transition(.opacity)
            }
        }
        .frame(minWidth: width, alignment: .trailing)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.easeOut(duration: 0.12), value: onButton)
    }
}

struct AmbientAge: View {
    let since: Date
    let fontSize: Double

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(AmbientTime.age(context.date.timeIntervalSince(since)))
                .font(.system(size: max(9, fontSize - 2)).monospacedDigit())
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
                .frame(minWidth: max(18, fontSize * 1.8), alignment: .trailing)
        }
    }
}

// MARK: - the app

/// Takes the key status it needs for Esc and its menus, without activating
/// the app or stealing focus from the window you were in.
final class AmbientMenuPanel: NSPanel {
    var onClose: () -> Void = {}
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onClose() }
}

/// The first click on a line's close button counts, even though the overlay
/// never becomes the key window.
final class AmbientHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AmbientPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AmbientApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
    private var middleClickTap: CFMachPort?
    private var menuPanel: AmbientMenuPanel?
    private var panelMonitors: [Any] = []
    private var pausedWatch: AnyCancellable?
    private var middleClickSwallowed = false
    private var trustPoll: Timer?

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
        panel.contentView = AmbientHostingView(rootView: AmbientOverlay(store: store))
        store.geometryChanged = { [weak self] in self?.positionOverlay() }
        positionOverlay()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(self, selector: #selector(positionOverlay),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        watchMiddleClicks()
        watchHover()
        handleSignals()

        switch mode {
        case .daemon:
            buildMenu()
            startSocket()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                              name: NSWorkspace.didWakeNotification, object: nil)
            store.restoreLocalStickies()
            store.startHubs()
            store.shortcutsChanged = { [weak self] in self?.updateShortcuts() }
            updateShortcuts()
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
        let width = min(store.settings.width + 12 + AmbientShadeGeometry.margin, frame.width)
        let x = store.settings.corner.hasSuffix("left") ? frame.minX : frame.maxX - width
        panel.setFrame(NSRect(x: x, y: frame.minY, width: width, height: frame.height), display: true)
    }

    // MARK: middle click

    /// The hit test, in screen coordinates (Cocoa, bottom-left origin).
    fileprivate func line(at point: NSPoint, reach: CGFloat = 0) -> String? {
        guard let panel, panel.frame.contains(point) else { return nil }
        let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
        let slack = store.settings.rowGap / 2
        guard let hit = store.rowFrames.first(where: { key, frame in
                  key != AmbientOverlay.clearKey && frame.insetBy(dx: -reach, dy: -slack).contains(local) }),
              store.lines.contains(where: { $0.id == hit.key }) else { return nil }
        return hit.key
    }

    // MARK: keyboard

    /// ⌃⌥⌫ closes the newest line, ⌃⌥⇧⌫ every line on screen. Carbon hot
    /// keys need no permission and never take focus from the app in front.
    private var hotKeys: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?

    private func updateShortcuts() {
        for key in hotKeys { UnregisterEventHotKey(key) }
        hotKeys = []
        guard store.settings.shortcuts else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, info in
                guard let event, let info else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                let app = Unmanaged<AmbientApp>.fromOpaque(info).takeUnretainedValue()
                MainActor.assumeIsolated { id.id == 2 ? app.store.dismissAll() : app.store.dismissNewest() }
                return noErr
            }
            InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        }
        let signature = OSType(0x5047_414D) // "PGAM"
        for (id, modifiers) in [(UInt32(1), controlKey | optionKey), (UInt32(2), controlKey | optionKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(kVK_Delete), UInt32(modifiers), EventHotKeyID(signature: signature, id: id),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeys.append(ref) }
            else { AmbientLog.write("shortcut \(id == 1 ? "⌃⌥⌫" : "⌃⌥⇧⌫") is taken by another app (\(status))") }
        }
    }

    /// With Accessibility allowed, an event tap takes the middle-click that
    /// lands on a line, so the app underneath never sees it. Every other
    /// click, and a middle-click anywhere else, goes through untouched.
    private func installMiddleClickTap() -> Bool {
        guard middleClickTap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let app = Unmanaged<AmbientApp>.fromOpaque(info).takeUnretainedValue()
            return MainActor.assumeIsolated { app.tapped(type, event) }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        middleClickTap = tap
        AmbientLog.write("middle-click: event tap on, clicks on lines no longer reach the app below")
        return true
    }

    fileprivate func tapped(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let middleClickTap { CGEvent.tapEnable(tap: middleClickTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.mouseEventButtonNumber) == 2 else { return Unmanaged.passUnretained(event) }
        if type == .otherMouseUp {
            defer { middleClickSwallowed = false }
            return middleClickSwallowed ? nil : Unmanaged.passUnretained(event)
        }
        // CG has its origin at the top of the main screen; Cocoa at the bottom.
        let p = event.location
        let height = NSScreen.screens.first?.frame.height ?? 0
        guard store.settings.middleClick,
              let key = line(at: NSPoint(x: p.x, y: height - p.y)) else { return Unmanaged.passUnretained(event) }
        middleClickSwallowed = true
        store.dismiss(key)
        return nil
    }

    /// macOS shows its own prompt only once per app; after that the only way is
    /// the Privacy pane. So: register (which adds `pager` to the list), then
    /// open that pane at the right place, and pick the grant up as it lands.
    @objc private func askAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) { _ = installMiddleClickTap(); return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        // The grant arrives while we run; pick it up without a restart.
        trustPoll?.invalidate()
        var tries = 0
        trustPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            Task { @MainActor in
                tries += 1
                if self?.installMiddleClickTap() == true || tries > 90 { timer.invalidate() }
            }
        }
    }

    /// The overlay ignores the mouse, except over a line: there it takes the
    /// pointer so the line can show its close button and a click lands on it
    /// instead of the app below. Off a line, clicks go straight through again.
    private func watchHover() {
        let moved: (NSEvent) -> Void = { [weak self] _ in
            let location = NSEvent.mouseLocation
            Task { @MainActor in self?.hover(at: location) }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: moved) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { moved($0); return $0 }) {
            monitors.append(local)
        }
        store.hoverChanged = { [weak self] in self?.hover(at: NSEvent.mouseLocation) }
    }

    private func hover(at point: NSPoint) {
        var key = line(at: point, reach: 4)
        // Moving down onto Clear all keeps the stream "pointed at".
        if key == nil, store.hovered != nil, let frame = store.rowFrames[AmbientOverlay.clearKey], let panel {
            let local = CGPoint(x: point.x - panel.frame.minX, y: panel.frame.maxY - point.y)
            if frame.insetBy(dx: -6, dy: -6).contains(local) { key = store.hovered }
        }
        if store.hovered != key { store.hovered = key }
        let ignore = key == nil
        if panel.ignoresMouseEvents != ignore { panel.ignoresMouseEvents = ignore }
    }

    private func watchMiddleClicks() {
        // Asked once, by the real overlay only (tests run with their own state dir).
        if !installMiddleClickTap(), store.settings.middleClick, !store.state.askedAccessibility,
           case .daemon = mode, ProcessInfo.processInfo.environment["PAGER_AMBIENT_DIR"] == nil {
            store.state.askedAccessibility = true
            store.scheduleStateSave()
            askAccessibility()
        }
        // Without the tap, a monitor still dismisses; the click also reaches the app below.
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.buttonNumber == 2, self?.middleClickTap == nil else { return }
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
        guard store.settings.middleClick, let key = line(at: point) else { return }
        store.dismiss(key)
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
            return store.status().merging(["ok": true,
                                           "middle_click": !store.settings.middleClick ? "off"
                                               : middleClickTap != nil ? "on" : "needs Accessibility",
                                           "shortcuts": hotKeys.isEmpty ? "off" : "\u{2303}\u{2325}\u{232B} newest, \u{2303}\u{2325}\u{21E7}\u{232B} all"],
                                          uniquingKeysWith: { $1 })
        case "event":
            guard let object = request["event"],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  var event = AmbientEvent.decode(data) else { return ["ok": false, "error": "unreadable event"] }
            event.origin = "local"
            store.ingest(event)
            return ["ok": true, "id": event.id, "shown": store.lines.contains(where: { $0.id == event.id })]
        case "dismiss" where request["which"] as? String == "newest":
            store.dismissNewest()
            return ["ok": true]
        case "dismiss" where request["which"] as? String == "all":
            store.dismissAll()
            return ["ok": true]
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
            if let minutes = request["minutes"] as? Double {
                store.pause(until: Date().addingTimeInterval(minutes * 60))
            } else if request["until"] as? String == "tomorrow" {
                store.pause(until: AmbientRules.tomorrowMorning())
            } else if (request["paused"] as? Bool) ?? !store.paused {
                store.pause(until: nil)
            } else {
                store.resume()
            }
            return ["ok": true, "paused": store.paused, "until": store.pausedUntil.map(AmbientTime.string) ?? ""]
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
        item.button?.image = AmbientIcon.image(paused: store.paused)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        pausedWatch = store.$paused.sink { [weak self] paused in
            self?.statusItem?.button?.image = AmbientIcon.image(paused: paused)
        }
    }

    /// The menu bar panel: a small dark sheet under the icon, square-ish like
    /// a menu (not a popover bubble), closed by a click anywhere else or Esc.
    @objc private func togglePanel() {
        if menuPanel?.isVisible == true { closePanel(); return }
        let actions = AmbientMenuActions(
            pause: { [weak self] until in self?.store.pause(until: until); self?.closePanel() },
            resume: { [weak self] in self?.store.resume(); self?.closePanel() },
            openLog: { [weak self] in self?.closePanel(); self?.showHistory() },
            openSettings: { [weak self] in self?.closePanel(); self?.showSettings() },
            allowMiddleClick: { [weak self] in self?.closePanel(); self?.askAccessibility() },
            quit: { NSApp.terminate(nil) },
            dismiss: { [weak self] key in self?.store.dismiss(key) },
            dismissAll: { [weak self] in self?.store.dismissAll() })
        let view = AmbientMenuView(store: store, actions: actions,
                                   middleClickNeedsPermission: store.settings.middleClick && middleClickTap == nil)
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = AmbientMenuPanel(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.appearance = NSAppearance(named: .darkAqua)
        host.wantsLayer = true
        host.layer?.cornerRadius = 7
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        panel.contentView = host
        panel.onClose = { [weak self] in self?.closePanel() }
        if let button = statusItem?.button, let window = button.window {
            let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let x = min(max(screen.minX + 6, anchor.maxX - size.width), screen.maxX - size.width - 6)
            panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 5))
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        menuPanel = panel
        statusItem?.button?.highlight(true)
        let close: (NSEvent) -> Void = { [weak self] _ in Task { @MainActor in self?.closePanel() } }
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: close) {
            panelMonitors.append(outside)
        }
        // Clicks in our own other windows close it too; not the icon (that
        // toggles) and not the Pause menu's own window.
        if let inside = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, let window = event.window else { return event }
            let isMenu = String(describing: type(of: window)).contains("Menu") && !(window is AmbientMenuPanel)
            if window !== self.menuPanel, window !== self.statusItem?.button?.window, !isMenu { self.closePanel() }
            return event
        }) {
            panelMonitors.append(inside)
        }
    }

    private func closePanel() {
        menuPanel?.orderOut(nil)
        menuPanel = nil
        statusItem?.button?.highlight(false)
        for monitor in panelMonitors { NSEvent.removeMonitor(monitor) }
        panelMonitors = []
    }


    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window(title: "Ambient settings", size: NSSize(width: 400, height: 640),
                                    view: AmbientSettingsView(store: store))
        }
        bringForward(settingsWindow)
    }

    @objc func showHistory() {
        if historyWindow == nil {
            historyWindow = window(title: "Ambient event log", size: NSSize(width: 760, height: 620),
                                   view: AmbientHistoryView(store: store))
        }
        bringForward(historyWindow)
    }

    private func window<V: View>(title: String, size: NSSize, view: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AmbientTheme.nsInk
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
