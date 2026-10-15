import AppKit
import SwiftUI

// MARK: - ambient: settings and history windows
//
// Both are deliberately small: a 380 pt utility panel with short sliders, and
// a searchable list. Everything in Settings is saved to ~/.pager/ambient.json
// as it changes, and applies to lines that arrive afterwards.

private let labelWidth: CGFloat = 96
private let sliderWidth: CGFloat = 140

struct AmbientSettingsView: View {
    @ObservedObject var store: AmbientStore

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double = 1, unit: String = "pt") -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: labelWidth, alignment: .leading)
            Slider(value: value, in: range, step: step).frame(width: sliderWidth)
            Text("\(value.wrappedValue, specifier: step < 1 ? "%.1f" : "%.0f")\(unit)")
                .monospacedDigit().foregroundColor(.secondary).frame(width: 42, alignment: .trailing)
        }
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: labelWidth, alignment: .leading)
            content()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ambient").font(.system(size: 15, weight: .semibold))
                Spacer()
                Toggle("Paused", isOn: $store.paused).toggleStyle(.checkbox)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    display
                    Divider()
                    DisclosureGroup("Effects") { effects.padding(.top, 6) }
                    DisclosureGroup("Sources") { AmbientSourcesView(store: store).padding(.top, 6) }
                    DisclosureGroup("Connections") { AmbientConnectionsView(store: store).padding(.top, 6) }
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(AmbientPaths.settings.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .font(.system(size: 10)).foregroundColor(.secondary.opacity(0.7))
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(14)
        .frame(minWidth: 380, maxWidth: 460, minHeight: 420)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Layout") {
                Picker("Layout", selection: $store.settings.layout) {
                    ForEach(EventLayout.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 140)
            }
            slider("Width / left edge", $store.settings.width, 260...900, step: 10)
            slider("Row gap", $store.settings.rowGap, 0...24)
            slider("Padding \u{2195}", $store.settings.rowPadding, 0...16)
            slider("Padding \u{2194}", $store.settings.sidePadding, 0...24)
            slider("Source width", $store.settings.sourceWidth, 40...160, step: 5)
            slider("Column gap", $store.settings.columnGap, 0...32)
            slider("Text size", $store.settings.fontSize, 10...17)
            slider("Shade", Binding(get: { store.settings.shade * 100 }, set: { store.settings.shade = $0 / 100 }),
                   0...100, step: 5, unit: "%")
                .help("A dark halo on the text and a soft shade behind the stream, so lines read on light windows.")
            row("Lifetime") {
                TextField("60", value: Binding(
                    get: { store.settings.lifetime },
                    set: { store.settings.lifetime = $0.isFinite ? min(Lifetime.maximum, max(1, $0)) : 60 }),
                    format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 52)
                Text("s default").foregroundColor(.secondary)
            }
            row("Lines") {
                Stepper("\(store.settings.lines) per event", value: $store.settings.lines, in: 1...5)
            }
            row("Max lines") {
                Stepper("\(store.settings.maxLines) on screen", value: $store.settings.maxLines, in: 1...100)
            }
            row("Corner") {
                Picker("Corner", selection: $store.settings.corner) {
                    ForEach(AmbientSettings.corners, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 110)
                Picker("Screen", selection: $store.settings.screen) {
                    ForEach(0..<max(1, NSScreen.screens.count), id: \.self) { Text("Screen \($0 + 1)").tag($0) }
                }.labelsHidden().frame(width: 84)
            }
            HStack(spacing: 12) {
                Toggle("Cards", isOn: $store.settings.cards)
                Toggle("Icons", isOn: $store.settings.icons)
                Toggle("Backdrop", isOn: $store.settings.backdrop)
                Toggle("Details", isOn: $store.settings.details).disabled(!store.settings.cards)
            }.toggleStyle(.checkbox)
            HStack(spacing: 12) {
                Toggle("Ages", isOn: $store.settings.ages)
                Toggle("Middle-click dismisses", isOn: $store.settings.middleClick)
            }.toggleStyle(.checkbox)
        }
    }

    private var effects: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Effect") {
                Picker("Effect", selection: $store.settings.effect) {
                    ForEach(TextEffect.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 140)
            }
            row("Apply to") {
                Picker("Target", selection: $store.settings.target) {
                    ForEach(EffectTarget.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 140)
            }
            slider("Cycle", $store.settings.period, 0.5...10, step: 0.5, unit: "s")
            if #unavailable(macOS 15) {
                Text("Effects need macOS 15. Lines show without them here.")
                    .font(.system(size: 10)).foregroundColor(.secondary)
            }
            Button("Show an example") { store.playDemo(count: 1, interval: 1) }
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
        VStack(alignment: .leading, spacing: 5) {
            if store.knownSources.isEmpty {
                Text("Sources appear here once they send something.").foregroundColor(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text("source").frame(width: 120, alignment: .leading)
                    Text("lifetime").frame(width: 58, alignment: .leading)
                    Text("colour").frame(width: 70, alignment: .leading)
                    Text("mute")
                }.font(.system(size: 10)).foregroundColor(.secondary)
            }
            ForEach(store.knownSources, id: \.self) { slug in
                HStack(spacing: 6) {
                    Text(slug).lineLimit(1).truncationMode(.middle).frame(width: 120, alignment: .leading)
                    TextField("default", text: Binding(
                        get: { (store.settings.sources[slug]?.lifetime).map(\.label) ?? "" },
                        set: { binding(slug, \.lifetime).wrappedValue = Lifetime.parse($0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 58)
                    TextField("#hex", text: Binding(
                        get: { store.settings.sources[slug]?.color ?? "" },
                        set: { binding(slug, \.color).wrappedValue = AmbientRules.validHex($0) ?? ($0.isEmpty ? nil : $0) }))
                        .textFieldStyle(.roundedBorder).frame(width: 70)
                    Toggle("", isOn: Binding(get: { binding(slug, \.mute).wrappedValue ?? false },
                                             set: { binding(slug, \.mute).wrappedValue = $0 ? true : nil }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
            }
            Text("Lifetime is seconds or \"sticky\".").font(.system(size: 10)).foregroundColor(.secondary)
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
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.settings.connections) { connection in
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { connection.enabled },
                        set: { value in
                            if let i = store.settings.connections.firstIndex(where: { $0.id == connection.id }) {
                                store.settings.connections[i].enabled = value
                            }
                        })).toggleStyle(.checkbox).labelsHidden()
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connection.name).lineLimit(1)
                        Text(connection.url).font(.system(size: 10)).foregroundColor(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }.frame(width: 190, alignment: .leading)
                    Text(store.phases[connection.id] ?? (connection.enabled ? "idle" : "off"))
                        .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1).frame(width: 70, alignment: .leading)
                    Button {
                        AmbientKeychain.save("", for: connection.id)
                        store.settings.connections.removeAll { $0.id == connection.id }
                    } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove")
                }
            }
            if store.settings.connections.isEmpty {
                Text(AmbientCredentials.connections(store.settings).isEmpty
                     ? "None. Local `pager event` lines still show."
                     : "Using PAGER_AMBIENT_URL from the environment.")
                    .foregroundColor(.secondary)
            }
            Divider()
            TextField("Hub URL, e.g. https://hub.example.com/v1/events", text: $url).textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                SecureField("Reader key", text: $key).textFieldStyle(.roundedBorder)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder).frame(width: 80)
                Button(busy ? "Checking\u{2026}" : "Connect", action: connect).disabled(busy || url.isEmpty || key.isEmpty)
            }
            if !message.isEmpty {
                Text(message).font(.system(size: 10)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() {
        guard let base = AmbientConnection.normalise(url) else { message = "That is not an http(s) URL."; return }
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
                    message = text
                    self.key = ""; url = ""; name = ""
                case .failure(let error):
                    message = error.description
                }
            }
        }
    }
}

// MARK: - history

struct AmbientHistoryView: View {
    @ObservedObject var store: AmbientStore
    @State private var search = ""
    @State private var source = ""
    @State private var connection = ""
    @State private var severity = 0

    private var filtered: [AmbientEvent] {
        store.history.filter { event in
            (source.isEmpty || event.source == source)
                && (connection.isEmpty || (event.connection ?? "local") == connection)
                && Severity.rank(event.severity) >= severity
                && (search.isEmpty || [event.label, event.source, event.subject ?? "", event.text, event.detail ?? "",
                                       event.type ?? ""].joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }

    private var connections: [String] { Array(Set(store.history.map { $0.connection ?? "local" })).sorted() }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                TextField("Search", text: $search).textFieldStyle(.roundedBorder)
                Picker("Connection", selection: $connection) {
                    Text("All hubs").tag("")
                    ForEach(connections, id: \.self) { Text(store.connectionName($0) ?? $0).tag($0) }
                }.labelsHidden().frame(width: 100)
                Picker("Source", selection: $source) {
                    Text("All sources").tag("")
                    ForEach(Array(Set(store.history.map(\.source))).sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 110)
                Picker("Severity", selection: $severity) {
                    ForEach(Severity.allCases, id: \.rank) { Text($0 == .debug ? "Any level" : "\($0.rawValue)+").tag($0.rank) }
                }.labelsHidden().frame(width: 90)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let rows = filtered
                    if rows.isEmpty {
                        Text(store.history.isEmpty ? "Nothing yet." : "No matches.")
                            .foregroundColor(.secondary).padding(.vertical, 16)
                    }
                    ForEach(rows, id: \.key) { event in
                        AmbientHistoryRow(store: store, event: event)
                        Divider()
                    }
                }
            }
            HStack {
                Text("\(filtered.count) of \(store.history.count)")
                Spacer()
                Text(AmbientPaths.history.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            }.font(.system(size: 10)).foregroundColor(.secondary)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(12)
        .frame(minWidth: 480, minHeight: 360)
    }
}

struct AmbientHistoryRow: View {
    @ObservedObject var store: AmbientStore
    let event: AmbientEvent

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm:ss"
        return f
    }()

    /// Only http(s), and only when clicked. Nothing from a hub opens itself.
    private var link: URL? {
        guard let text = event.url, let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    var body: some View {
        let look = AmbientRules.resolve(event, store.settings)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let at = event.happened {
                    AmbientAge(since: at, fontSize: 13)
                    Text(Self.clock.string(from: at)).foregroundColor(.secondary)
                }
                Text(store.label(for: event)).foregroundColor(Color(hex: look.sourceColor) ?? .secondary).lineLimit(1)
                if let type = event.type { Text(type).foregroundColor(.secondary.opacity(0.7)).lineLimit(1) }
                if look.lifetime.isSticky { Image(systemName: "pin").foregroundColor(.secondary) }
                Spacer()
                if let link {
                    Button { NSWorkspace.shared.open(link) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.borderless).help(link.absoluteString)
                }
                if event.dismissedAt == nil {
                    Button { store.dismiss(event.key) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Dismiss")
                } else {
                    Button { store.undismiss(event.key) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                        .buttonStyle(.borderless).help("Undismiss")
                }
                Button { store.present(event, again: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Show again")
            }
            .font(.system(size: 10.5))
            HStack(spacing: 0) {
                StyledMessage(text: event.text, context: event.subject.map { $0 + "  " } ?? "",
                              color: Color(hex: look.accent) ?? .primary, fontSize: 12, lineLimit: 3)
            }
            .opacity(event.dismissedAt == nil ? 1 : 0.55)
            if let detail = event.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(4)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .background(Color.black.opacity(0.75).cornerRadius(6).padding(.vertical, 2))
        .environment(\.colorScheme, .dark)
    }
}
