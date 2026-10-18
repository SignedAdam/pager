import AppKit
import SwiftUI

// MARK: - ambient: settings and the event log
//
// Same ink, hairlines and lime as the menu bar panel. Settings is a compact
// column of cards, saved to ~/.pager/ambient.json as it changes. The event log
// is the whole history: searchable, filterable, grouped by day, with the
// actions on the row you point at.

private let labelWidth: CGFloat = 92

/// A titled card that groups settings.
private struct Card<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            AmbientSectionTitle(text: title, trailing: trailing)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AmbientTheme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AmbientTheme.hairline))
    }
}

/// A plain field on a sunken surface, for search and short values.
struct AmbientField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String? = nil
    var mono = false
    var secure = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundColor(AmbientTheme.faint) }
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain)
            .font(mono ? AmbientTheme.mono(11.5) : .system(size: 12))
            .foregroundColor(AmbientTheme.text)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(AmbientTheme.hairline))
    }
}

/// A native pop-up button in the dark, for every filter and picker.
struct AmbientChoice<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10)).foregroundColor(AmbientTheme.faint) }
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// On/off as a settings row: the name, a dim hint, a small switch on the right.
struct AmbientSwitchRow: View {
    let title: String
    var hint: String? = nil
    @Binding var isOn: Bool
    var disabled = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundColor(AmbientTheme.text)
            if let hint { Text(hint).font(.system(size: 11)).foregroundColor(AmbientTheme.faint).lineLimit(1) }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        }
        .opacity(disabled ? 0.4 : 1)
        .disabled(disabled)
    }
}

struct AmbientSettingsView: View {
    @ObservedObject var store: AmbientStore

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double = 1, unit: String = "pt") -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(AmbientTheme.dim)
                .frame(width: labelWidth, alignment: .leading)
            // No `step:` on the slider itself: on macOS that draws a tick per step.
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = ($0 / step).rounded() * step }), in: range)
                .controlSize(.mini)
            Text("\(value.wrappedValue, specifier: step < 1 ? "%.1f" : "%.0f")\(unit)")
                .font(AmbientTheme.mono(11)).foregroundColor(AmbientTheme.text.opacity(0.8))
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(AmbientTheme.dim)
                .frame(width: labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: AmbientIcon.image(paused: store.paused, size: 16)).renderingMode(.template)
                    .foregroundColor(AmbientTheme.text)
                Text("Settings").font(.system(size: 14, weight: .semibold)).foregroundColor(AmbientTheme.text)
                Spacer()
                Text(store.paused ? "Paused" : "Live").font(.system(size: 12))
                    .foregroundColor(store.paused ? AmbientTheme.amber : AmbientTheme.lime)
                Toggle("", isOn: Binding(get: { !store.paused },
                                         set: { $0 ? store.resume() : store.pause(until: nil) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 12)
            // The content is pinned to the window's width, so no row can push the
            // cards out to the window edges.
            GeometryReader { geometry in
                ScrollView {
                VStack(spacing: 10) {
                        Card(title: "Layout") { layout }
                        Card(title: "Spacing") { spacing }
                        Card(title: "Lines") { lines }
                        Card(title: "Look") { look }
                        Card(title: "Effects", trailing: effectsNote) { effects }
                        Card(title: "Sources", trailing: "override what events ask for") { AmbientSourcesView(store: store) }
                        Card(title: "Hubs") { AmbientConnectionsView(store: store) }
                        Text(AmbientPaths.settings.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(AmbientTheme.mono(10)).foregroundColor(AmbientTheme.faint).padding(.top, 2)
                    }
                    .frame(width: max(0, geometry.size.width - 36))
                    .padding(.horizontal, 18).padding(.bottom, 18)
                }
            }
        }
        .tint(AmbientTheme.lime)
        .frame(minWidth: 380, idealWidth: 400, maxWidth: 480, minHeight: 440)
        .background(AmbientTheme.ink)
        .environment(\.colorScheme, .dark)
    }

    private var effectsNote: String? {
        if #available(macOS 15, *) { return nil }
        return "needs macOS 15"
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Columns") {
                AmbientChoice(options: EventLayout.allCases.map { ($0, $0.label) }, selection: $store.settings.layout)
            }
            row("Corner") {
                AmbientChoice(options: AmbientSettings.corners.map { ($0, $0.replacingOccurrences(of: "-", with: " ").capitalized) },
                              selection: $store.settings.corner)
                AmbientChoice(options: (0..<max(1, NSScreen.screens.count)).map { ($0, "Screen \($0 + 1)") },
                              selection: $store.settings.screen)
            }
            slider("Width", $store.settings.width, 260...900, step: 10)
            slider("Source column", $store.settings.sourceWidth, 40...160, step: 5)
            slider("Text size", $store.settings.fontSize, 10...17)
        }
    }

    private var spacing: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Row gap", $store.settings.rowGap, 0...24)
            slider("Padding \u{2195}", $store.settings.rowPadding, 0...16)
            slider("Padding \u{2194}", $store.settings.sidePadding, 0...24)
            slider("Column gap", $store.settings.columnGap, 0...32)
        }
    }

    private var lines: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Stays for") {
                AmbientField(placeholder: "60", text: Binding(
                    get: { String(Int(store.settings.lifetime)) },
                    set: { if let v = Double($0) { store.settings.lifetime = min(Lifetime.maximum, max(1, v)) } }),
                    mono: true)
                    .frame(width: 64)
                Text("seconds by default").font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            }
            row("On screen") {
                AmbientField(placeholder: "20", text: Binding(
                    get: { String(store.settings.maxLines) },
                    set: { if let v = Int($0) { store.settings.maxLines = min(100, max(1, v)) } }), mono: true)
                    .frame(width: 64)
                Text("lines at most").font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            }
            row("Stickies") {
                AmbientField(placeholder: "12", text: Binding(
                    get: { store.settings.stickyHours == store.settings.stickyHours.rounded() ? String(Int(store.settings.stickyHours)) : String(store.settings.stickyHours) },
                    set: { if let v = Double($0) { store.settings.stickyHours = min(720, max(0, v)) } }), mono: true)
                    .frame(width: 64)
                Text("hours on screen, 0 = until dismissed").font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            }
            row("Each event") {
                AmbientField(placeholder: "1", text: Binding(
                    get: { String(store.settings.lines) },
                    set: { if let v = Int($0) { store.settings.lines = min(5, max(1, v)) } }), mono: true)
                    .frame(width: 64)
                Text("lines, 1 to 5").font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            }
        }
    }

    private var look: some View {
        VStack(alignment: .leading, spacing: 10) {
            slider("Shade", Binding(get: { store.settings.shade * 100 }, set: { store.settings.shade = $0 / 100 }),
                   0...100, step: 5, unit: "%")
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1).padding(.vertical, 2)
            AmbientSwitchRow(title: "Source icons", hint: "GitHub, Stripe\u{2026} marks", isOn: $store.settings.sourceIcons)
            AmbientSwitchRow(title: "Ages", hint: "now, 4m, 2h", isOn: $store.settings.ages)
            AmbientSwitchRow(title: "Type icons", isOn: $store.settings.icons)
            AmbientSwitchRow(title: "Cards", isOn: $store.settings.cards)
            AmbientSwitchRow(title: "Details in cards", isOn: $store.settings.details, disabled: !store.settings.cards)
            AmbientSwitchRow(title: "Hard backdrop", hint: "instead of the shade", isOn: $store.settings.backdrop)
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1).padding(.vertical, 2)
            AmbientSwitchRow(title: "Middle-click closes", isOn: $store.settings.middleClick)
            AmbientSwitchRow(title: "Keyboard", hint: "\u{2303}\u{2325}\u{232B} newest \u{00B7} \u{2303}\u{2325}\u{21E7}\u{232B} all", isOn: $store.settings.shortcuts)
            AmbientSwitchRow(title: "Hub panels", hint: "events may raise a panel", isOn: $store.settings.panels)
        }
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Effect") {
                AmbientChoice(options: TextEffect.allCases.map { ($0, $0.label) }, selection: $store.settings.effect)
            }
            row("Apply to") {
                AmbientChoice(options: EffectTarget.allCases.map { ($0, $0.label) }, selection: $store.settings.target)
            }
            slider("Cycle", $store.settings.period, 0.5...10, step: 0.5, unit: "s")
            Button("Show an example") { store.playDemo(count: 1, interval: 1) }
                .buttonStyle(AmbientButtonStyle(compact: true))
        }
    }
}

/// Per source: lifetime, colour, mute. These beat whatever the event asks for.
struct AmbientSourcesView: View {
    @ObservedObject var store: AmbientStore

    private func binding<T>(_ slug: String, _ key: WritableKeyPath<SourceOverride, T>) -> Binding<T> {
        Binding(get: { (store.settings.sources[slug] ?? SourceOverride())[keyPath: key] },
                set: { value in
                    var entry = store.settings.sources[slug] ?? SourceOverride()
                    entry[keyPath: key] = value
                    store.settings.sources[slug] = entry == SourceOverride() ? nil : entry
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.knownSources.isEmpty {
                Text("Sources appear here once they send something.")
                    .font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            } else {
                HStack(spacing: 6) {
                    Text("source").frame(maxWidth: .infinity, alignment: .leading)
                    Text("stays").padding(.leading, 9).frame(width: 62, alignment: .leading)
                    Text("colour").padding(.leading, 9).frame(width: 72, alignment: .leading)
                    Text("mute").frame(width: 34)
                }
                .font(.system(size: 10)).foregroundColor(AmbientTheme.faint)
            }
            ForEach(store.knownSources, id: \.self) { slug in
                let look = AmbientRules.resolve(AmbientEvent(id: "s", source: slug, text: ""), store.settings)
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        if let brand = look.brand {
                            AmbientMark(brand: brand, color: Color(hex: look.sourceColor) ?? AmbientTheme.dim, size: 11.5)
                        }
                        Text(slug).font(.system(size: 12)).foregroundColor(AmbientTheme.text)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    AmbientField(placeholder: "default", text: Binding(
                        get: { (store.settings.sources[slug]?.lifetime).map(\.label) ?? "" },
                        set: { binding(slug, \.lifetime).wrappedValue = Lifetime.parse($0) }), mono: true)
                        .frame(width: 62)
                    AmbientField(placeholder: "#hex", text: Binding(
                        get: { store.settings.sources[slug]?.color ?? "" },
                        set: { binding(slug, \.color).wrappedValue = AmbientRules.validHex($0) ?? ($0.isEmpty ? nil : $0) }),
                        mono: true)
                        .frame(width: 72)
                    Toggle("", isOn: Binding(get: { binding(slug, \.mute).wrappedValue ?? false },
                                             set: { binding(slug, \.mute).wrappedValue = $0 ? true : nil }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().frame(width: 34)
                }
            }
            if !store.knownSources.isEmpty {
                Text("\"Stays\" is seconds, or sticky.").font(.system(size: 10.5)).foregroundColor(AmbientTheme.faint)
            }
        }
    }
}

/// Hubs this Mac reads from. Adding one checks `{url}/info` first, so a typo
/// or a publish key is caught here rather than as a silent reconnect loop.
struct AmbientConnectionsView: View {
    @ObservedObject var store: AmbientStore
    @State private var url = ""
    @State private var key = ""
    @State private var name = ""
    @State private var message = ""
    @State private var failed = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.settings.connections) { connection in
                let phase = store.phases[connection.id] ?? (connection.enabled ? "idle" : "off")
                HStack(spacing: 9) {
                    AmbientStatusDot(color: !connection.enabled ? AmbientTheme.faint
                                     : phase == "connected" ? AmbientTheme.lime : AmbientTheme.amber,
                                     glow: phase == "connected")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.name).font(.system(size: 12, weight: .medium)).foregroundColor(AmbientTheme.text)
                        Text(connection.url).font(AmbientTheme.mono(10)).foregroundColor(AmbientTheme.faint)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Text(phase).font(.system(size: 11)).foregroundColor(AmbientTheme.dim).lineLimit(1)
                    Toggle("", isOn: Binding(
                        get: { connection.enabled },
                        set: { value in
                            if let i = store.settings.connections.firstIndex(where: { $0.id == connection.id }) {
                                store.settings.connections[i].enabled = value
                            }
                        })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    Button {
                        AmbientKeychain.save("", for: connection.id)
                        store.settings.connections.removeAll { $0.id == connection.id }
                    } label: { Image(systemName: "trash").font(.system(size: 11)) }
                        .buttonStyle(.plain).foregroundColor(AmbientTheme.faint).help("Remove this hub")
                }
            }
            if store.settings.connections.isEmpty {
                Text(AmbientCredentials.connections(store.settings).isEmpty
                     ? "No hubs. Local `pager event` lines still show."
                     : "Using PAGER_AMBIENT_URL from the environment.")
                    .font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
            }
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1).padding(.vertical, 2)
            AmbientField(placeholder: "https://hub.example.com/v1/events", text: $url, icon: "link", mono: true)
            HStack(spacing: 6) {
                AmbientField(placeholder: "Reader key", text: $key, icon: "key", secure: true)
                AmbientField(placeholder: "Name", text: $name).frame(width: 84)
                Button(busy ? "Checking\u{2026}" : "Connect", action: connect)
                    .buttonStyle(AmbientButtonStyle(prominent: !url.isEmpty && !key.isEmpty, compact: true))
                    .disabled(busy || url.isEmpty || key.isEmpty)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 11)).foregroundColor(failed ? AmbientTheme.red : AmbientTheme.lime)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() {
        guard let base = AmbientConnection.normalise(url) else {
            failed = true; message = "That is not an http(s) URL."; return
        }
        busy = true
        message = ""
        let key = self.key, wanted = name
        DispatchQueue.global(qos: .userInitiated).async {
            let result = HubHTTP.info(base: base, key: key)
            DispatchQueue.main.async {
                busy = false
                switch AmbientCommands.adopt(result: result, base: base, key: key, name: wanted, sources: [],
                                             settings: &store.settings) {
                case .success(let text):
                    failed = false
                    message = text
                    self.key = ""; url = ""; name = ""
                case .failure(let error):
                    failed = true
                    message = error.description
                }
            }
        }
    }
}

// MARK: - the event log

struct AmbientHistoryView: View {
    @ObservedObject var store: AmbientStore
    @State private var search = ""
    @State private var source = ""
    @State private var connection = ""
    @State private var severity = 0
    @State private var hideDismissed = false
    @State private var expanded: String?

    private var filtered: [AmbientEvent] {
        store.history.filter { event in
            (source.isEmpty || event.source == source)
                && (connection.isEmpty || (event.connection ?? "local") == connection)
                && Severity.rank(event.severity) >= severity
                && (!hideDismissed || event.dismissedAt == nil)
                && (search.isEmpty || [event.label, event.source, event.subject ?? "", event.text, event.detail ?? "",
                                       event.type ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    private var days: [(day: Date, events: [AmbientEvent])] {
        let calendar = Calendar.current
        var out: [(day: Date, events: [AmbientEvent])] = []
        for event in filtered {
            let day = calendar.startOfDay(for: event.happened ?? Date())
            if let last = out.last, last.day == day { out[out.count - 1].events.append(event) } else { out.append((day, [event])) }
        }
        return out
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return Self.dayFormat.string(from: day)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if filtered.isEmpty { empty }
                    ForEach(days, id: \.day) { group in
                        Section {
                            ForEach(group.events, id: \.key) { event in
                                AmbientHistoryRow(store: store, event: event, expanded: expanded == event.key) {
                                    expanded = expanded == event.key ? nil : event.key
                                }
                            }
                        } header: {
                            HStack {
                                Text(dayTitle(group.day).uppercased()).font(.system(size: 9.5, weight: .semibold))
                                    .tracking(0.8).foregroundColor(AmbientTheme.lime.opacity(0.75))
                                Spacer()
                                Text("\(group.events.count)").font(AmbientTheme.mono(9.5)).foregroundColor(AmbientTheme.faint)
                            }
                            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 3)
                            .background(AmbientTheme.ink.opacity(0.96))
                        }
                    }
                }
                .padding(.bottom, 10)
            }
            Rectangle().fill(AmbientTheme.hairline).frame(height: 1)
            HStack {
                Text("\(filtered.count) of \(store.history.count) events")
                Spacer()
                Text(AmbientPaths.history.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }
            .font(AmbientTheme.mono(10)).foregroundColor(AmbientTheme.faint)
            .padding(.horizontal, 16).padding(.vertical, 7)
        }
        .frame(minWidth: 560, minHeight: 380)
        .background(AmbientTheme.ink)
        .environment(\.colorScheme, .dark)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(nsImage: AmbientIcon.image(size: 28)).renderingMode(.template).foregroundColor(AmbientTheme.faint)
            Text(store.history.isEmpty ? "Nothing yet" : "No matches")
                .font(.system(size: 13, weight: .medium)).foregroundColor(AmbientTheme.dim)
            Text(store.history.isEmpty ? "Events from your hubs and `pager event` land here." : "Try fewer filters.")
                .font(.system(size: 11.5)).foregroundColor(AmbientTheme.faint)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(nsImage: AmbientIcon.image(paused: store.paused, size: 16)).renderingMode(.template)
                    .foregroundColor(AmbientTheme.text)
                Text("Event log").font(.system(size: 14, weight: .semibold)).foregroundColor(AmbientTheme.text)
                Spacer()
                AmbientField(placeholder: "Search", text: $search, icon: "magnifyingglass").frame(width: 220)
            }
            HStack(spacing: 6) {
                let hubs = Array(Set(store.history.map { $0.connection ?? "local" })).sorted()
                AmbientChoice(options: [("", "All hubs")] + hubs.map { ($0, store.connectionName($0) ?? $0) },
                              selection: $connection, icon: "point.3.connected.trianglepath.dotted")
                AmbientChoice(options: [("", "All sources")] + Array(Set(store.history.map(\.source))).sorted().map { ($0, $0) },
                              selection: $source, icon: "square.stack")
                AmbientChoice(options: Severity.allCases.map { ($0.rank, $0 == .debug ? "Any level" : "\($0.rawValue.capitalized) and up") },
                              selection: $severity, icon: "exclamationmark.triangle")
                Toggle("Hide dismissed", isOn: $hideDismissed).toggleStyle(.checkbox).controlSize(.small)
                    .font(.system(size: 11.5)).foregroundColor(AmbientTheme.dim)
                Spacer()
            }
        }
    }
}

struct AmbientHistoryRow: View {
    @ObservedObject var store: AmbientStore
    let event: AmbientEvent
    let expanded: Bool
    let toggle: () -> Void
    @State private var hover = false

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy, HH:mm:ss"
        return f
    }()

    /// Only http(s), and only when clicked. Nothing from a hub opens itself.
    private var link: URL? {
        guard let text = event.url, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private func action(_ symbol: String, _ help: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 10, weight: .medium)).frame(width: 20, height: 16)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(AmbientTheme.raisedHover))
        }
        .buttonStyle(.plain).foregroundColor(AmbientTheme.text).help(help)
    }

    var body: some View {
        let look = AmbientRules.resolve(event, store.settings)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(event.happened.map { Self.clock.string(from: $0) } ?? "")
                    .font(AmbientTheme.mono(10.5)).foregroundColor(AmbientTheme.faint).frame(width: 36, alignment: .leading)
                AmbientLevelTag(severity: event.severity)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if let brand = look.brand {
                        AmbientMark(brand: brand, color: Color(hex: look.sourceColor) ?? AmbientTheme.dim, size: 12)
                    }
                    Text(store.label(for: event)).font(.system(size: 12)).foregroundColor(AmbientTheme.dim).lineLimit(1)
                }
                .frame(width: 118, alignment: .leading)
                StyledMessage(text: event.text, context: event.subject.map { $0 + "  " } ?? "",
                              color: Color(hex: look.accent) ?? AmbientTheme.text, fontSize: 12,
                              lineLimit: expanded ? 3 : 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(event.dismissedAt == nil ? 1 : 0.45)
                ZStack(alignment: .trailing) {
                    HStack(spacing: 6) {
                        if look.lifetime.isSticky && event.dismissedAt == nil {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundColor(AmbientTheme.lime.opacity(0.8))
                        }
                        if link != nil { Image(systemName: "link").font(.system(size: 9)).foregroundColor(AmbientTheme.faint) }
                        if let at = event.happened { AmbientAge(since: at, fontSize: 12.5) }
                    }
                    .opacity(hover ? 0 : 1)
                    HStack(spacing: 4) {
                        if let link { action("arrow.up.right", link.absoluteString) { NSWorkspace.shared.open(link) } }
                        action("arrow.clockwise", "Show again") { store.present(event, again: true) }
                        if event.dismissedAt == nil {
                            action("xmark", "Dismiss") { store.dismiss(event.key) }
                        } else {
                            action("arrow.uturn.backward", "Undismiss") { store.undismiss(event.key) }
                        }
                    }
                    .opacity(hover ? 1 : 0)
                }
                .frame(width: 84, alignment: .trailing)
            }
            if expanded { details(look) }
        }
        .padding(.horizontal, 16).padding(.vertical, expanded ? 3 : 0)
        .background(hover || expanded ? AmbientTheme.raised : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: toggle)
    }

    private func details(_ look: ResolvedPresentation) -> some View {
        let facts: [(String, String)] = [
            ("when", event.happened.map { Self.full.string(from: $0) } ?? "-"),
            ("type", event.type ?? "-"),
            ("level", event.severity ?? "info"),
            ("stays", look.lifetime.isSticky ? "until dismissed" : "\(look.lifetime.label) s"),
            ("hub", store.connectionName(event.connection) ?? "this Mac"),
            ("id", event.id),
        ] + (event.url.map { [("url", $0)] } ?? [])
            + (event.dismissedAt.map { [("dismissed", Self.full.string(from: $0))] } ?? [])
        return VStack(alignment: .leading, spacing: 4) {
            if let detail = event.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 12)).foregroundColor(AmbientTheme.text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 3)
            }
            ForEach(facts, id: \.0) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(fact.0).font(AmbientTheme.mono(10)).foregroundColor(AmbientTheme.faint).frame(width: 64, alignment: .leading)
                    Text(fact.1).font(AmbientTheme.mono(10.5)).foregroundColor(AmbientTheme.dim)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.leading, 36 + 9 + 58 + 9)
        .padding(.bottom, 4)
    }
}
