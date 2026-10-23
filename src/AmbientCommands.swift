import AppKit
import Foundation

// MARK: - ambient: the command line
//
//   pager ambient [--demo|--status|--install|--uninstall|--quit|--settings|--history|--selftest]
//   pager ambient connect <url> --key <key> [--name N] [--sources a,b]
//   pager ambient connections | disconnect <name>
//   pager event --source NAME --text "..." [options]

enum Ambient {
    static let label = "com.signedadam.pager.ambient"

    static let usage = """
    usage: pager ambient [option]        the quiet stream in a corner of the screen

      (no option)            run the overlay. One per user; a second exits 0
      --demo                 play the 50 sample events once, then stop
      --interval <s>         seconds between demo events, default 2
      --status               running? connected? last event, cursors
      --settings             open the settings window of the running overlay
      --history              open the history window
      --quit                 stop the running overlay
      --pause <15m|1h|tomorrow|off>   quiet for a while; --resume ends it
      --dismiss newest|all   close lines from the keyboard (also ⌃⌥⌫ and ⌃⌥⇧⌫)
      --install              run at login and restart on crash (LaunchAgent)
      --uninstall            remove the LaunchAgent
      --selftest             check the parts that need no screen
      --idle-check           count redraws while idle, every window off screen
      --snapshot <png>       render the overlay over --on page|white|black|mixed|<image>

    pager ambient connect <url> --key <reader key> [--name N] [--sources a,b]
                             add a hub. Checks <url>/info, keeps the key in the Keychain
      --key-file F --key-var NAME   read the key from an env file instead
    pager ambient connections            list hubs
    pager ambient disconnect <name>      remove one

    pager event --text "..." [options]   one line on the overlay, no hub needed
      --source <name>        the left column. default "local"
      --detail <text>        dim, shown in cards and history
      --subject <text>       short dim label before the message
      --type <word>          e.g. deploy.failed. default "note"
      --severity <level>     debug, info, notice, warn, error, critical
      --lifetime <n|sticky>  seconds on screen, or until dismissed
      --layout <split|inline>
      --effect <name>        none, blink, flash, highlight, wave, gradient
      --target <emphasis|message>
      --period <s>           effect cycle, 0.5 to 10
      --color "#hex"         accent for **emphasis**
      --lines <n>            lines per event, 1 to 5 (local only)
      --url <https://...>    opened from history when clicked, never by itself
      --hub <url>            publish to a hub instead (key: --key or PAGER_AMBIENT_PUBLISH_KEY)
      --key <key>            publish key for --hub

    Files live in ~/.pager: ambient.json (settings), ambient-state.json,
    events.jsonl (history; older events in events-<date>.jsonl beside it,
    never deleted), ambient.log. Protocol: docs/protocol.md

    """

    @MainActor
    static func main(_ arguments: [String]) -> Int32 {
        let first = arguments.first ?? ""
        switch first {
        case "connect": return AmbientCommands.connect(Array(arguments.dropFirst()))
        case "connections": return AmbientCommands.connections()
        case "disconnect": return AmbientCommands.disconnect(Array(arguments.dropFirst()))
        case "--help", "-h", "help": print(usage); return 0
        case "--status": return AmbientCommands.status()
        case "--selftest": return AmbientSelfTest.run()
        case "--idle-check":
            AmbientIdleCheck.isolate()
            return run(.check)
        case "--snapshot": return AmbientSnapshot.run(Array(arguments.dropFirst()))
        case "--snapshot-ui": return AmbientSnapshot.ui(Array(arguments.dropFirst()))
        case "--install": return AmbientCommands.install()
        case "--uninstall": return AmbientCommands.uninstall()
        case "--quit": return AmbientCommands.send(["op": "quit"], done: "stopped")
        case "--pause": return AmbientCommands.pause(arguments.dropFirst().first ?? "")
        case "--resume": return AmbientCommands.send(["op": "pause", "paused": false], done: "resumed")
        case "--dismiss":
            let which = arguments.dropFirst().first ?? "newest"
            guard which == "newest" || which == "all" else {
                FileHandle.standardError.write(Data("usage: pager ambient --dismiss newest|all\n".utf8)); return 2
            }
            return AmbientCommands.send(["op": "dismiss", "which": which], done: which == "all" ? "cleared" : "dismissed")
        case "--settings": return AmbientCommands.send(["op": "settings"], done: nil)
        case "--history": return AmbientCommands.send(["op": "history"], done: nil)
        case "--demo":
            var interval = 2.0
            if let i = arguments.firstIndex(of: "--interval"), i + 1 < arguments.count, let v = Double(arguments[i + 1]) {
                interval = max(0.05, v)
            }
            var count = 50
            if let i = arguments.firstIndex(of: "--count"), i + 1 < arguments.count, let v = Int(arguments[i + 1]) {
                count = max(1, v)
            }
            if AmbientSocket.request(["op": "demo", "count": count, "interval": interval]) != nil {
                print("  playing \(count) sample events on the running overlay")
                return 0
            }
            return run(.demo(count: count, interval: interval))
        case "":
            return run(.daemon)
        default:
            FileHandle.standardError.write(Data("pager ambient: unknown option \(first)\n\n\(usage)".utf8))
            return 2
        }
    }

    /// One overlay per user. The lock is the authority; the socket answers
    /// "who is it" for the message.
    @MainActor
    private static func run(_ mode: AmbientApp.Mode) -> Int32 {
        AmbientPaths.ensure()
        let lock = open(AmbientPaths.lock, O_CREAT | O_RDWR, 0o644)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let pid = AmbientSocket.request(["op": "ping"])?["pid"] as? Int
            print("pager ambient is already running" + (pid.map { " (pid \($0))" } ?? ""))
            return 0
        }
        let app = NSApplication.shared
        let delegate = AmbientApp(mode: mode)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        return 0
    }
}

enum AmbientCommands {
    static func send(_ request: [String: Any], done: String?) -> Int32 {
        guard let reply = AmbientSocket.request(request) else {
            print("pager ambient is not running")
            return 1
        }
        if let done, reply["ok"] as? Bool == true { print("  \(done)") }
        return reply["ok"] as? Bool == true ? 0 : 1
    }

    static func pause(_ text: String) -> Int32 {
        var request: [String: Any] = ["op": "pause"]
        let lower = text.lowercased()
        if lower == "tomorrow" { request["until"] = "tomorrow" }
        else if lower == "off" || lower == "resume" { request["paused"] = false }
        else if lower.isEmpty || lower == "on" { request["paused"] = true }
        else if let n = Double(lower.dropLast()), lower.hasSuffix("m") { request["minutes"] = n }
        else if let n = Double(lower.dropLast()), lower.hasSuffix("h") { request["minutes"] = n * 60 }
        else if let n = Double(lower) { request["minutes"] = n }
        else {
            FileHandle.standardError.write(Data("usage: pager ambient --pause <15m|1h|tomorrow|off>\n".utf8)); return 2
        }
        guard let reply = AmbientSocket.request(request) else { print("pager ambient is not running"); return 1 }
        guard reply["ok"] as? Bool == true else { print("pager ambient: \(reply["error"] as? String ?? "no answer")"); return 1 }
        let until = (reply["until"] as? String).flatMap(AmbientTime.parse)
        if reply["paused"] as? Bool == true {
            let clock = DateFormatter()
            clock.dateFormat = "EEE HH:mm"
            print("  paused" + (until.map { " until \(clock.string(from: $0))" } ?? ""))
        } else {
            print("  resumed")
        }
        return 0
    }

    // MARK: status

    static func status() -> Int32 {
        let dim = "\u{1B}[2m", off = "\u{1B}[0m"
        let reply = AmbientSocket.request(["op": "status"])
        let state = AmbientState.load()
        func line(_ name: String, _ value: String) { print("  \(dim)\(name.padding(toLength: 11, withPad: " ", startingAt: 0))\(off)\(value)") }
        print("")
        if let reply {
            var running = "running (pid \(reply["pid"] as? Int ?? 0))"
            if (reply["paused"] as? Bool) == true {
                running += ", paused" + ((reply["paused_until"] as? String).flatMap(AmbientTime.parse)
                    .map { date -> String in
                        guard date < Date().addingTimeInterval(400 * 86_400) else { return "" }
                        let clock = DateFormatter()
                        clock.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
                        return " until " + clock.string(from: date)
                    } ?? "")
            }
            line("ambient", running)
        } else {
            line("ambient", "not running")
        }
        let connections = (reply?["connections"] as? [[String: Any]])
            ?? AmbientCredentials.connections(AmbientSettings.load()).map {
                ["id": $0.id, "name": $0.name, "url": $0.url, "phase": $0.enabled ? "-" : "disabled",
                 "cursor": state.cursors[$0.id] ?? ""]
            }
        if connections.isEmpty { line("hubs", "none, local only") }
        for c in connections {
            let cursor = (c["cursor"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "none"
            var text = "\(c["phase"] as? String ?? "-")  \(dim)\(c["url"] as? String ?? "")  cursor \(cursor)"
            if let gaps = c["gaps"] as? Int, gaps > 0 { text += "  gaps \(gaps)" }
            if let from = c["key_source"] as? String { text += "  key: \(from)" }
            line("hub", "\(c["name"] as? String ?? "?")  " + text + off)
        }
        let lastAt = (reply?["last_event_at"] as? String).flatMap(AmbientTime.parse) ?? state.lastEventAt
        if let lastAt {
            let text = reply?["last_event"] as? String ?? state.lastEventText ?? ""
            let source = reply?["last_source"] as? String ?? state.lastEventSource ?? ""
            let age = AmbientTime.age(Date().timeIntervalSince(lastAt))
            line("last event", "\(age == "now" ? "just now" : age + " ago")  \(source)  \(dim)\(text.prefix(60))\(off)")
        } else {
            line("last event", "none yet")
        }
        if let middle = reply?["middle_click"] as? String { line("click", "middle-click " + middle) }
        if let keys = reply?["shortcuts"] as? String { line("keys", keys) }
        if let reply { line("on screen", "\(reply["visible"] as? Int ?? 0) line(s), \(reply["history"] as? Int ?? 0) in history") }
        print("")
        return 0
    }

    // MARK: connections

    /// Shared by `connect` and the settings window: check what /info said,
    /// keep the key in the Keychain, add or update the connection.
    static func adopt(result: Result<HubInfo, AmbientError>, base: URL, key: String, name: String,
                      sources: [String], settings: inout AmbientSettings,
                      keyFile: String? = nil, keyVar: String? = nil) -> Result<String, AmbientError> {
        let info: HubInfo
        switch result {
        case .failure(let error): return .failure(error)
        case .success(let value): info = value
        }
        if info.keyKind == "publish" {
            return .failure(AmbientError("that is a publish key. Ambient reads, so it needs a reader key."))
        }
        let display = name.isEmpty ? info.name : name
        var connection = AmbientConnection(id: AmbientConnection.slug(display), name: display,
                                           url: base.absoluteString, sources: sources)
        if let index = settings.connections.firstIndex(where: { $0.url == connection.url || $0.name == display }) {
            connection.id = settings.connections[index].id
            settings.connections[index] = connection
        } else {
            var id = connection.id, n = 2
            while settings.connections.contains(where: { $0.id == id }) { id = "\(connection.id)-\(n)"; n += 1 }
            connection.id = id
            settings.connections.append(connection)
        }
        if let keyFile {
            connection.keyFile = keyFile
            connection.keyVar = keyVar
            if let index = settings.connections.firstIndex(where: { $0.id == connection.id }) {
                settings.connections[index] = connection
            }
        } else if !AmbientKeychain.save(key, for: connection.id) {
            settings.connections.removeAll { $0.id == connection.id }
            return .failure(AmbientError("could not save the key in the Keychain"))
        }
        var text = "connected to \(info.name)"
        if let reader = info.reader { text += " as \(reader)" }
        text += ". Sources: " + (info.sources.isEmpty ? "none granted yet" : info.sources.joined(separator: ", "))
        if !sources.isEmpty { text += ". Following: " + sources.joined(separator: ", ") }
        return .success(text)
    }

    static func connect(_ arguments: [String]) -> Int32 {
        var url = "", key = "", name = "", sources: [String] = [], keyFile = "", keyVar = AmbientCredentials.readKeyVar
        var index = 0
        while index < arguments.count {
            let flag = arguments[index], next = index + 1 < arguments.count ? arguments[index + 1] : ""
            switch flag {
            case "--key": key = next; index += 1
            case "--key-file": keyFile = next; index += 1
            case "--key-var": keyVar = next; index += 1
            case "--name": name = next; index += 1
            case "--sources", "--source":
                sources = next.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                index += 1
            default: if url.isEmpty && !flag.hasPrefix("--") { url = flag }
            }
            index += 1
        }
        // `--key -` reads it from stdin, so it stays out of shell history.
        if key == "-" { key = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces) ?? "" }
        // `--key-file F --key-var NAME`: the key stays in that env file and is
        // read from there each start. Nothing goes to the Keychain, so a
        // rebuilt binary never needs approval. Good for a LaunchAgent.
        if !keyFile.isEmpty {
            guard let fromFile = AmbientCredentials.fromFile(keyFile, name: keyVar) else {
                FileHandle.standardError.write(Data("pager ambient: no \(keyVar)= in \(keyFile)\n".utf8)); return 1
            }
            key = fromFile
        }
        guard let base = AmbientConnection.normalise(url), !key.isEmpty else {
            FileHandle.standardError.write(Data("usage: pager ambient connect <https://hub/base> --key <reader key> [--name N] [--sources a,b]\n".utf8))
            return 2
        }
        var settings = AmbientSettings.load()
        switch adopt(result: HubHTTP.info(base: base, key: key), base: base, key: key, name: name,
                     sources: sources, settings: &settings,
                     keyFile: keyFile.isEmpty ? nil : keyFile, keyVar: keyFile.isEmpty ? nil : keyVar) {
        case .failure(let error):
            FileHandle.standardError.write(Data("pager ambient: \(error)\n".utf8))
            return 1
        case .success(let text):
            settings.save()
            print("  \(text)")
            if AmbientSocket.request(["op": "reload"]) != nil { print("  the running overlay picked it up") }
            return 0
        }
    }

    static func connections() -> Int32 {
        let settings = AmbientSettings.load()
        let live = (AmbientSocket.request(["op": "status"])?["connections"] as? [[String: Any]]) ?? []
        let all = AmbientCredentials.connections(settings)
        if all.isEmpty { print("  no hubs. add one with: pager ambient connect <url> --key <reader key>"); return 0 }
        let state = AmbientState.load()
        for c in all {
            let phase = live.first(where: { $0["id"] as? String == c.id })?["phase"] as? String
                ?? (c.enabled ? "not running" : "disabled")
            let filter = c.sources.isEmpty ? "" : "  sources \(c.sources.joined(separator: ","))"
            print("  \(c.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(c.url)  \(phase)  cursor \(state.cursors[c.id] ?? "none")\(filter)")
        }
        return 0
    }

    static func disconnect(_ arguments: [String]) -> Int32 {
        guard let name = arguments.first else {
            FileHandle.standardError.write(Data("usage: pager ambient disconnect <name>\n".utf8)); return 2
        }
        var settings = AmbientSettings.load()
        guard let index = settings.connections.firstIndex(where: { $0.name == name || $0.id == name }) else {
            FileHandle.standardError.write(Data("pager ambient: no hub called \(name)\n".utf8)); return 1
        }
        let removed = settings.connections.remove(at: index)
        AmbientKeychain.save("", for: removed.id)
        settings.save()
        var state = AmbientState.load()
        state.cursors[removed.id] = nil
        state.save()
        print("  removed \(removed.name)")
        _ = AmbientSocket.request(["op": "reload"])
        return 0
    }

    // MARK: LaunchAgent

    static var plistPath: String { NSHomeDirectory() + "/Library/LaunchAgents/\(Ambient.label).plist" }

    static var binary: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    /// KeepAlive on failure only: Quit from the menu exits 0 and stays quit,
    /// a crash comes back.
    static func plist(binary: String, logDirectory: String) -> String {
        func xml(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(Ambient.label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(xml(binary))</string>
                <string>ambient</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key>
            <dict><key>SuccessfulExit</key><false/></dict>
            <key>ThrottleInterval</key><integer>10</integer>
            <key>ProcessType</key><string>Interactive</string>
            <key>LimitLoadToSessionType</key><string>Aqua</string>
            <key>StandardOutPath</key><string>\(xml(logDirectory))/ambient.out.log</string>
            <key>StandardErrorPath</key><string>\(xml(logDirectory))/ambient.out.log</string>
        </dict>
        </plist>

        """
    }

    @discardableResult
    static func launchctl(_ arguments: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }

    static func install() -> Int32 {
        AmbientPaths.ensure()
        // A hand-started overlay would make the agent's copy exit "already running".
        if AmbientSocket.request(["op": "quit"]) != nil { Thread.sleep(forTimeInterval: 0.8) }
        try? FileManager.default.createDirectory(atPath: (plistPath as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        do {
            try plist(binary: binary, logDirectory: AmbientPaths.directory).write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("pager ambient: cannot write \(plistPath): \(error)\n".utf8)); return 1
        }
        let domain = "gui/\(getuid())"
        launchctl(["bootout", "\(domain)/\(Ambient.label)"])
        let status = launchctl(["bootstrap", domain, plistPath])
        guard status == 0 else {
            FileHandle.standardError.write(Data("pager ambient: launchctl bootstrap failed (\(status))\n".utf8)); return 1
        }
        print("  installed \(plistPath)\n  runs \(binary) ambient at login, restarts if it crashes")
        return 0
    }

    static func uninstall() -> Int32 {
        launchctl(["bootout", "gui/\(getuid())/\(Ambient.label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
        print("  removed \(plistPath)")
        return 0
    }
}

// MARK: - pager event

enum AmbientPublish {
    struct Request {
        var event: AmbientEvent
        var hub: URL?
        var key: String?
    }

    static let limits = (text: 300, detail: 1000, subject: 80)

    /// Arguments to an event, with every check a hub would make, so a mistake
    /// is caught here with a message instead of a 400 later.
    static func parse(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment,
                      now: Date = Date()) -> Result<Request, AmbientError> {
        var event = AmbientEvent(id: AmbientEvent.localID(now: now), source: "local", text: "")
        var display = AmbientDisplay()
        var hub = environment[AmbientCredentials.hubVar] ?? ""
        var key = environment[AmbientCredentials.publishKeyVar] ?? ""
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count else { return .failure(AmbientError("\(flag) needs a value")) }
            let value = arguments[index + 1]
            switch flag {
            case "--source": event.source = value
            case "--text": event.text = value
            case "--detail": event.detail = value
            case "--subject": event.subject = value
            case "--type": event.type = value
            case "--severity": event.severity = value
            case "--url": event.url = value
            case "--lifetime":
                guard let lifetime = Lifetime.parse(value) else {
                    return .failure(AmbientError("--lifetime is seconds from 1 to 86400, or sticky"))
                }
                display.lifetime = lifetime
            case "--layout": display.layout = value
            case "--effect": display.effect = value
            case "--target": display.target = value
            case "--period":
                guard let period = Double(value), period >= 0.5, period <= 10 else {
                    return .failure(AmbientError("--period is seconds from 0.5 to 10"))
                }
                display.period = period
            case "--color", "--colour": display.color = value
            case "--lines":
                guard let lines = Int(value), (1...5).contains(lines) else { return .failure(AmbientError("--lines is 1 to 5")) }
                display.lines = lines
            case "--hub": hub = value
            case "--key": key = value
            default: return .failure(AmbientError("unknown option \(flag). See pager ambient --help"))
            }
            index += 2
        }
        let source = event.source.trimmingCharacters(in: .whitespaces)
        event.sourceName = source
        event.source = AmbientConnection.slug(source)
        if event.text.trimmingCharacters(in: .whitespaces).isEmpty { return .failure(AmbientError("--text is required")) }
        if event.text.count > limits.text { return .failure(AmbientError("--text is at most \(limits.text) characters")) }
        if (event.detail?.count ?? 0) > limits.detail { return .failure(AmbientError("--detail is at most \(limits.detail) characters")) }
        if (event.subject?.count ?? 0) > limits.subject { return .failure(AmbientError("--subject is at most \(limits.subject) characters")) }
        if event.type == nil { event.type = "note" }
        if let type = event.type, type.range(of: "^[a-z0-9._-]{1,48}$", options: .regularExpression) == nil {
            return .failure(AmbientError("--type is 1 to 48 of a-z 0-9 . _ -"))
        }
        if let severity = event.severity, Severity(rawValue: severity) == nil {
            return .failure(AmbientError("--severity is one of " + Severity.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        if let layout = display.layout, EventLayout(rawValue: layout) == nil {
            return .failure(AmbientError("--layout is split or inline"))
        }
        if let effect = display.effect, TextEffect(rawValue: effect) == nil {
            return .failure(AmbientError("--effect is one of " + TextEffect.allCases.map(\.rawValue).joined(separator: ", ")))
        }
        if let target = display.target, EffectTarget(rawValue: target) == nil {
            return .failure(AmbientError("--target is emphasis or message"))
        }
        if let color = display.color {
            guard let hex = AmbientRules.validHex(color) else { return .failure(AmbientError("--color is #rrggbb")) }
            display.color = hex
        }
        if let url = event.url {
            guard let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else {
                return .failure(AmbientError("--url must be an http(s) URL"))
            }
        }
        event.display = display.isEmpty ? nil : display
        event.severity = event.severity ?? "info"
        event.occurredAt = now
        event.receivedAt = now
        event.origin = "local"
        var request = Request(event: event)
        if !hub.isEmpty {
            guard let base = AmbientConnection.normalise(hub) else { return .failure(AmbientError("--hub must be an http(s) URL")) }
            guard !key.isEmpty else {
                return .failure(AmbientError("--hub needs a publish key: --key or \(AmbientCredentials.publishKeyVar)"))
            }
            request.hub = base
            request.key = key
        }
        return .success(request)
    }

    /// The body a hub expects. No `source`: a publish key carries its own.
    static func hubBody(_ event: AmbientEvent) -> [String: Any] {
        var body: [String: Any] = ["type": event.type ?? "note", "text": event.text, "severity": event.severity ?? "info",
                                   "idempotency_key": event.id]
        if let detail = event.detail { body["detail"] = detail }
        if let subject = event.subject { body["subject"] = subject }
        if let url = event.url { body["url"] = url }
        if let at = event.occurredAt { body["occurred_at"] = AmbientTime.string(at) }
        if let display = event.display?.forHub,
           let data = try? JSONEncoder().encode(display),
           let object = try? JSONSerialization.jsonObject(with: data) {
            body["display"] = object
        }
        return body
    }

    static func main(_ arguments: [String]) -> Int32 {
        if arguments.first == "--help" || arguments.first == "-h" { print(Ambient.usage); return 0 }
        let request: Request
        switch parse(arguments) {
        case .failure(let error):
            FileHandle.standardError.write(Data("pager event: \(error)\n".utf8))
            return 2
        case .success(let value): request = value
        }
        if let hub = request.hub, let key = request.key {
            let result = HubPublish.send(base: hub, key: key, body: hubBody(request.event))
            guard result.ok else {
                FileHandle.standardError.write(Data("pager event: \(hub.absoluteString): \(result.message)\n".utf8))
                return 1
            }
            let id = ((try? JSONSerialization.jsonObject(with: Data(result.message.utf8))) as? [String: Any])?["id"] as? String
            print(id ?? "sent")
            return 0
        }
        let object = (try? JSONSerialization.jsonObject(with: request.event.json)) ?? [:]
        if let reply = AmbientSocket.request(["op": "event", "event": object]), reply["ok"] as? Bool == true {
            print(request.event.id)
            return 0
        }
        // Nobody is drawing. The line still goes into history.
        AmbientHistory.append(request.event)
        FileHandle.standardError.write(Data("pager event: ambient is not running; saved to history only\n".utf8))
        print(request.event.id)
        return 0
    }
}
