import AppKit

// MARK: - ambient: self test
//
// `pager ambient --selftest` (and `make check`): the parts that decide what
// shows, for how long, and what a hub said, checked without drawing anything.

enum AmbientSelfTest {
    private static var failures = 0
    private static var count = 0

    private static func expect(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        count += 1
        if !ok {
            failures += 1
            print("  FAIL  \(name)  \(detail())")
        }
    }

    static func run() -> Int32 {
        // Never touch real history or settings.
        let dir = NSTemporaryDirectory() + "pager-selftest-\(getpid())"
        setenv("PAGER_AMBIENT_DIR", dir, 1)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        brands(); ages(); lifetimes(); events(); rules(); sse(); settings(); history(); publish(); connections(); plist()

        print(failures == 0 ? "  ambient selftest: \(count) checks ok" : "  ambient selftest: \(failures) of \(count) failed")
        return failures == 0 ? 0 : 1
    }

    private static func brands() {
        func brand(_ source: String, _ name: String? = nil) -> AmbientBrand? {
            var event = AmbientEvent(id: "b", source: source, text: "x")
            event.sourceName = name
            return AmbientBrand.find(event)
        }
        expect(brand("github-acme")?.mark == "github", "slug word finds a brand")
        expect(brand("ci", "GitHub Actions")?.mark == "githubactions", "squeezed name wins")
        expect(brand("google-calendar")?.mark == "googlecalendar", "two words")
        expect(brand("coolify")?.symbol == "shippingbox.fill", "symbol brands")
        expect(brand("narkis") == nil && AmbientBrand.monogram("Narkis")?.symbol == "n.circle.fill", "monogram fallback")
        expect(AmbientBrand.readable("#181717") == "#e6edf3", "near-black brands turn light")
        expect(AmbientBrand.readable("#2088ff") == "#2088ff", "bright brands stay")
        var settings = AmbientSettings()
        settings.sources["coolify"] = SourceOverride(icon: "github")
        let look = AmbientRules.resolve(AmbientEvent(id: "c", source: "coolify", text: "x"), settings)
        expect(look.brand?.mark == "github", "per-source icon override")
        var hinted = AmbientEvent(id: "h", source: "narkis", text: "x")
        hinted.sourceIcon = "stripe"
        expect(AmbientRules.resolve(hinted, AmbientSettings()).brand?.mark == "stripe", "hub source_icon picks the mark")
        let calendar = Calendar.current
        let morning = AmbientRules.tomorrowMorning(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: Date())!)
        expect(calendar.component(.hour, from: morning) == 9 && !calendar.isDateInToday(morning), "pause until tomorrow is 9:00")
        var state = AmbientState()
        state.pausedUntil = AmbientTime.parse("2030-01-01T09:00:00Z")
        state.save()
        expect(AmbientState.load().pausedUntil == state.pausedUntil, "pause survives a restart")
    }

    private static func ages() {
        let cases: [(TimeInterval, String)] = [(-3, "now"), (0, "now"), (4.9, "now"), (12, "12s"), (59, "59s"),
                                               (60, "1m"), (245, "4m"), (3599, "59m"), (3600, "1h"), (3 * 3600 + 5, "3h"),
                                               (86_399, "23h"), (2 * 86_400 + 10, "2d"), (.infinity, "now")]
        for (seconds, want) in cases {
            expect(AmbientTime.age(seconds) == want, "age(\(seconds))", "got \(AmbientTime.age(seconds))")
        }
        let left: [(TimeInterval, String)] = [(0, "0s"), (-3, "0s"), (45, "45s"), (59.2, "60s"), (61, "2m"),
                                              (599, "10m"), (3600, "1h"), (3601, "2h")]
        for (seconds, want) in left {
            expect(AmbientTime.left(seconds) == want, "left(\(seconds))", "got \(AmbientTime.left(seconds))")
        }
    }

    private static func lifetimes() {
        expect(Lifetime.parse("sticky") == .sticky, "lifetime sticky")
        expect(Lifetime.parse(" 90 ") == .seconds(90), "lifetime 90")
        expect(Lifetime.parse("0") == nil && Lifetime.parse("86401") == nil && Lifetime.parse("x") == nil, "lifetime bounds")
        expect(Lifetime.seconds(0).clamped == .seconds(1) && Lifetime.seconds(1e9).clamped == .seconds(86_400), "lifetime clamp")
        let decoded = try? JSONDecoder().decode([Lifetime].self, from: Data(#"[60, "sticky", "30"]"#.utf8))
        expect(decoded == [.seconds(60), .sticky, .seconds(30)], "lifetime json")
        let encoded = (try? JSONEncoder().encode([Lifetime.seconds(60), .sticky])).map { String(decoding: $0, as: UTF8.self) }
        expect(encoded == #"[60,"sticky"]"#, "lifetime encode", encoded ?? "")
    }

    private static func events() {
        let json = #"""
        {"id":"evt_1","cursor":1734,"source":"narkis","source_name":"Narkis","source_color":"#C7FF00","type":"sale",
         "severity":"info","text":"**$29** · Creator","occurred_at":"2026-10-15T10:02:03Z",
         "received_at":"2026-10-15T10:02:04.250Z","display":{"lifetime":"sticky","effect":"wave","layout":"nonsense"},
         "data":{"x":1},"dismissed_at":null}
        """#
        guard let event = AmbientEvent.decode(Data(json.utf8)) else { expect(false, "decode event"); return }
        expect(event.cursor == "1734", "numeric cursor becomes text")
        expect(event.display?.lifetime == .sticky && event.display?.effect == "wave", "display decoded")
        expect(event.receivedAt == AmbientTime.parse("2026-10-15T10:02:04.250Z"), "fractional seconds")
        expect(event.dismissedAt == nil && event.origin == nil, "no origin from the wire")
        expect(AmbientEvent.decode(Data(#"{"text":"no id"}"#.utf8)) == nil, "event without id rejected")
        let bad = AmbientEvent.decode(Data(#"{"id":"e","source":"s","text":"t","display":{"lifetime":-5,"period":"x"}}"#.utf8))
        expect(bad != nil && bad?.display?.lifetime != nil, "odd display values do not drop the event")
        var local = event
        local.origin = "local"
        let back = AmbientEvent.decode(local.json)
        expect(back == local, "event round trip")
        var hub = event
        hub.origin = "hub"; hub.connection = "work"
        expect(hub.key == "work/evt_1" && local.key == "local/evt_1", "keys are per connection")
        expect(AmbientEvent.localID().hasPrefix("loc_"), "local ids")
        panels()
    }

    private static func panels() {
        func decode(_ data: String) -> AmbientEvent? {
            AmbientEvent.decode(Data((#"{"id":"p","source":"narkis-app","text":"**Payment failed** · Pro","severity":"error","#
                                      + #""subject":"api","url":"https://x.test/a'b","data":"# + data + "}").utf8))
        }
        expect(decode("null")?.panel == nil && decode(#"{"x":1}"#)?.panel == nil, "no data.panel, no panel")
        expect(decode(#"{"panel":false}"#)?.panel == nil, "panel false is no panel")
        expect(decode(#"{"panel":true}"#)?.panel == AmbientPanelRequest(), "panel true")
        let custom = decode(#"{"panel":{"title":" Card declined ","pinned":false,"seconds":2,"sound":"/etc/x"}}"#)
        expect(custom?.panel?.title == "Card declined" && custom?.panel?.seconds == 2, "panel object decoded")
        expect(decode(#"{"panel":"yes"}"#)?.panel == nil && decode(#"{"panel":"yes"}"#) != nil, "odd panel value ignored, event kept")
        guard let event = decode(#"{"panel":true}"#), let custom, let request = custom.panel else { return }
        let args = AmbientPanelRequest.arguments(event, AmbientPanelRequest(), label: "Narkis")
        func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        expect(value(args, "--title") == "Payment failed · Pro", "panel title is the plain text")
        expect(value(args, "--sound") == "alarm" && args.contains("--pinned") && value(args, "--accent") == "#ff5f57",
               "error panels alarm, red, pinned")
        expect(value(args, "--chip") == "api" && value(args, "--source") == "Narkis", "chip and source")
        expect(value(args, "--action") == #"Open:open 'https://x.test/a'\''b'"#, "url action is quoted")
        let mild = AmbientPanelRequest.arguments(custom, request, label: "Narkis")
        expect(value(mild, "--title") == "Card declined" && value(mild, "--body") == "**Payment failed** · Pro",
               "custom title keeps the text as body")
        expect(value(mild, "--sound") == "alarm" && value(mild, "--seconds") == "5" && !mild.contains("--pinned"),
               "unknown sound falls back, seconds clamped, pinned false honoured")
        var info = event
        info.severity = "info"; info.url = "http://plain.test"
        let infoArgs = AmbientPanelRequest.arguments(info, AmbientPanelRequest(), label: "Narkis")
        expect(value(infoArgs, "--sound") == "rise" && value(infoArgs, "--seconds") == "300" && !infoArgs.contains("--action"),
               "info panels rise, five minutes, http links dropped")
        expect(AmbientSettings().panels, "hub panels on by default")
    }

    private static func rules() {
        var settings = AmbientSettings()
        let now = Date()
        var event = AmbientEvent(id: "e", source: "deploys", text: "x")
        event.receivedAt = now.addingTimeInterval(-30)

        var look = AmbientRules.resolve(event, settings)
        expect(look.lifetime == .seconds(60) && look.layout == .split && look.effect == .none, "global defaults")
        var decision = AmbientRules.decide(event, look, now: now)
        expect(decision.show && !decision.fresh, "30s old line still shows, quietly")
        expect(abs((decision.expires ?? now).timeIntervalSince(now.addingTimeInterval(30))) < 0.01, "expiry counts from received_at")

        event.receivedAt = now.addingTimeInterval(-61)
        expect(!AmbientRules.decide(event, look, now: now).show, "stale catch-up line stays in history only")

        event.display = AmbientDisplay(lifetime: .sticky)
        look = AmbientRules.resolve(event, settings)
        decision = AmbientRules.decide(event, look, now: now)
        expect(decision.show && decision.expires != nil, "sticky shows, and by default leaves after 12 h")
        expect(!AmbientRules.decide(event, look, now: now.addingTimeInterval(13 * 3600)).show, "an old sticky leaves the screen")
        var forever = settings
        forever.stickyHours = 0
        decision = AmbientRules.decide(event, AmbientRules.resolve(event, forever), now: now.addingTimeInterval(86_400 * 3))
        expect(decision.show && decision.expires == nil, "sticky_hours 0 keeps it until dismissed")
        event.dismissedAt = now
        expect(!AmbientRules.decide(event, look, now: now).show, "dismissed sticky does not")
        event.dismissedAt = nil

        event.display = AmbientDisplay(lifetime: .seconds(10), layout: "inline", effect: "blink", period: 50, color: "#ABCDEF")
        event.receivedAt = now.addingTimeInterval(-2)
        look = AmbientRules.resolve(event, settings)
        expect(look.lifetime == .seconds(10) && look.layout == .inline && look.effect == .blink, "event hints apply")
        expect(look.period == 10 && look.accent == "#abcdef", "period clamped, colour normalised")
        expect(AmbientRules.decide(event, look, now: now).fresh, "a 2s old line is fresh")

        settings.sources["deploys"] = SourceOverride(lifetime: .seconds(5), color: "#112233", mute: nil)
        look = AmbientRules.resolve(event, settings)
        expect(look.lifetime == .seconds(5) && look.sourceColor == "#112233", "per-source override beats the event")
        settings.sources["deploys"]?.mute = true
        look = AmbientRules.resolve(event, settings)
        expect(!AmbientRules.decide(event, look, now: now).show, "muted source hidden")

        var future = AmbientEvent(id: "f", source: "s", text: "x")
        future.receivedAt = now.addingTimeInterval(120)
        expect(AmbientRules.anchor(future, now: now) == now, "future timestamps count as now")

        var error = AmbientEvent(id: "g", source: "s", text: "x")
        error.severity = "critical"
        expect(AmbientRules.accent(for: error) == "#ff5f57", "errors are red")

        for attempt in 0..<12 {
            let low = AmbientRules.backoff(attempt: attempt, random: 0), high = AmbientRules.backoff(attempt: attempt, random: 1)
            expect(low >= 0.5 && high <= 60 && low <= high, "backoff bounds \(attempt)", "\(low) \(high)")
        }
        expect(AmbientRules.backoff(attempt: 3, random: 1) == 8, "backoff doubles")
    }

    private static func sse() {
        var parser = SSEParser()
        let stream = "retry: 3000\r\n: keepalive\r\n\r\nid: 7\nevent: event\ndata: {\"a\":\ndata: 1}\n\n"
            + "event: state\ndata: {\"id\":\"e\",\"dismissed_at\":null}\n\n" + "data: plain\n\n" + "id: 9\nevent: ev"
        let frames = parser.feed(Data(stream.utf8))
        expect(frames.count == 3, "sse frame count", "\(frames)")
        expect(frames.first == SSEFrame(id: "7", event: "event", data: "{\"a\":\n1}"), "multi-line data")
        expect(frames.dropFirst().first?.event == "state" && frames.dropFirst().first?.id == "7", "state keeps last id")
        expect(frames.last?.event == "message", "default event name")
        expect(parser.retry == 3000, "retry field")
        let rest = parser.feed(Data("ent\ndata: {}\n\n".utf8))
        expect(rest == [SSEFrame(id: "9", event: "event", data: "{}")] && parser.lastEventID == "9", "split across chunks")
        var empty = SSEParser()
        expect(empty.feed(line: "") == nil && empty.feed(line: ": hi") == nil, "comments and blank lines alone are nothing")
    }

    private static func settings() {
        let partial = try? JSONDecoder().decode(AmbientSettings.self, from: Data(#"""
        {"width": 5000, "row_gap": 3, "effect": "sparkle", "corner": "middle",
         "connections": [{"url": "https://hub.example.com/v1/events/", "name": "Work Hub"}, {"url": "x", "id": "work-hub"}]}
        """#.utf8))
        expect(partial?.width == 1200 && partial?.rowGap == 3, "settings clamp and partial load")
        expect(partial?.effect == TextEffect.none && partial?.corner == "top-right", "unknown values fall back")
        expect(partial?.connections.count == 1 && partial?.connections.first?.id == "work-hub", "connection ids unique, derived from name")
        expect(partial?.connections.first?.base?.absoluteString == "https://hub.example.com/v1/events", "base URL normalised")
        let defaults = AmbientSettings()
        defaults.save()
        expect(AmbientSettings.load() == defaults, "settings round trip")
        var state = AmbientState()
        state.cursors = ["work": "17"]
        state.lastEventAt = AmbientTime.parse("2026-10-15T10:00:00Z")
        state.save()
        expect(AmbientState.load() == state, "state round trip")
    }

    private static func history() {
        var a = AmbientEvent(id: "a", source: "s", text: "**one**")
        a.origin = "local"
        var b = AmbientEvent(id: "a", source: "s", text: "two")
        b.origin = "hub"; b.connection = "work"; b.cursor = "5"
        AmbientHistory.append(a)
        AmbientHistory.append(b)
        AmbientHistory.appendState(key: b.key, dismissedAt: Date())
        AmbientHistory.append(a)
        let loaded = AmbientHistory.load()
        expect(loaded.count == 2, "history dedupes per connection", "\(loaded.count)")
        expect(loaded.first(where: { $0.connection == "work" })?.dismissedAt != nil, "state lines apply")
        let rows = AmbientHistory.logRows()
        expect(rows.contains { $0["title"] == "one" && $0["event"] == "ambient" }, "log rows are plain text")
        expect(rows.contains { $0["id"] == "\u{00B7}5" && $0["connection"] == "work" }, "log row ids use the cursor")
        archives()
    }

    /// Rotation keeps every file, and reading crosses them: newest first,
    /// state lines from newer files applied, search reaching the oldest.
    private static func archives() {
        let files = FileManager.default
        for file in AmbientHistory.files() { try? files.removeItem(atPath: file) }
        func event(_ id: String, _ text: String) -> AmbientEvent {
            var event = AmbientEvent(id: id, source: "s", text: text)
            event.origin = "local"
            return event
        }
        // What 1.1.2 and earlier left: one previous file.
        try? (String(decoding: event("old", "from the legacy file").json, as: UTF8.self) + "\n")
            .write(toFile: AmbientHistory.legacy, atomically: true, encoding: .utf8)
        let saved = AmbientHistory.rotateBytes
        AmbientHistory.rotateBytes = 1  // every write after the first starts a new file
        AmbientHistory.append(event("e1", "the needle"))
        for id in ["e2", "e3", "e4"] { AmbientHistory.append(event(id, "hay")) }
        AmbientHistory.appendState(key: "local/e1", dismissedAt: Date())
        AmbientHistory.appendState(key: "local/e2", dismissedAt: Date())
        AmbientHistory.appendState(key: "local/e2", dismissedAt: nil)
        AmbientHistory.append(event("e5", "hay"))
        AmbientHistory.rotateBytes = saved
        let kept = AmbientHistory.files().filter { files.fileExists(atPath: $0) }
        expect(kept.count == 9 && kept.first == AmbientHistory.legacy && kept.last == AmbientHistory.path,
               "rotation archives, never deletes", "\(kept.map { ($0 as NSString).lastPathComponent })")
        let loaded = AmbientHistory.load()
        expect(loaded.map(\.id) == ["old", "e1", "e2", "e3", "e4", "e5"], "every file loads, oldest first", "\(loaded.map(\.id))")
        expect(loaded.first { $0.id == "e1" }?.dismissedAt != nil, "a state line in a newer file applies")
        expect(loaded.first { $0.id == "e2" }?.dismissedAt == nil, "the latest state line wins")
        let reader = AmbientHistory.Reader()
        expect(reader.next(2).map(\.id) == ["e5", "e4"] && !reader.exhausted, "newest first, older files left unread")
        expect(reader.next(10).map(\.id) == ["e3", "e2", "e1", "old"] && reader.exhausted, "the next page goes on")
        var query = AmbientHistory.Query()
        query.search = "NEEDLE"
        let found = AmbientHistory.Reader(skipping: ["local/e5"]).next(10, where: query.matches)
        expect(found.map(\.id) == ["e1"], "search reaches the archives", "\(found.map(\.id))")
        query.search = "legacy"
        expect(AmbientHistory.Reader().next(10, where: query.matches).map(\.id) == ["old"], "search reaches the legacy file")
        query = AmbientHistory.Query()
        query.hideDismissed = true
        expect(AmbientHistory.Reader().next(10, where: query.matches).map(\.id) == ["e5", "e4", "e3", "e2", "old"],
               "filters see dismissals from newer files")
    }

    private static func publish() {
        func parse(_ args: [String], _ env: [String: String] = [:]) -> Result<AmbientPublish.Request, AmbientError> {
            AmbientPublish.parse(args, environment: env)
        }
        guard case .success(let ok) = parse(["--source", "My App", "--text", "**hi**", "--lifetime", "sticky",
                                             "--effect", "wave", "--color", "C7FF00", "--lines", "2"]) else {
            expect(false, "event parse"); return
        }
        expect(ok.event.source == "my-app" && ok.event.sourceName == "My App", "source slug and label")
        expect(ok.event.display?.lifetime == .sticky && ok.event.display?.color == "#c7ff00", "display flags")
        expect(ok.hub == nil && ok.event.type == "note" && ok.event.severity == "info", "local by default")
        let body = AmbientPublish.hubBody(ok.event)
        expect(body["source"] == nil && (body["display"] as? [String: Any])?["lines"] == nil, "hub body has no source or lines")
        expect(body["idempotency_key"] as? String == ok.event.id, "hub body is idempotent")
        let bad: [[String]] = [["--source", "x"], ["--text", String(repeating: "a", count: 301)], ["--text", "x", "--severity", "loud"],
                               ["--text", "x", "--lifetime", "0"], ["--text", "x", "--effect", "sparkle"],
                               ["--text", "x", "--url", "file:///etc/passwd"], ["--text", "x", "--type", "Has Space"],
                               ["--text", "x", "--color", "red"], ["--text", "x", "--hub", "https://h.example/v1"],
                               ["--text", "x", "--bogus", "1"], ["--text"]]
        for args in bad {
            if case .success = parse(args) { expect(false, "rejects \(args.joined(separator: " "))") } else { expect(true, "") }
        }
        if case .success(let viaEnv) = parse(["--text", "x"], ["PAGER_AMBIENT_HUB": "https://h.example/v1/events/",
                                                               "PAGER_AMBIENT_PUBLISH_KEY": "k"]) {
            expect(viaEnv.hub?.absoluteString == "https://h.example/v1/events" && viaEnv.key == "k", "hub from environment")
        } else { expect(false, "hub from environment") }
    }

    private static func connections() {
        let file = AmbientPaths.directory + "/keys.env"
        AmbientPaths.ensure()
        try? "# keys\nexport OTHER=1\nexport WORK_KEY=\"abc123\"\n".write(toFile: file, atomically: true, encoding: .utf8)
        expect(AmbientCredentials.fromFile(file, name: "WORK_KEY") == "abc123", "env file keys")
        expect(AmbientCredentials.fromFile(file, name: "MISSING") == nil, "env file missing key")
        var connection = AmbientConnection(id: "work", name: "work", url: "https://h.example/v1")
        connection.keyFile = file; connection.keyVar = "WORK_KEY"
        expect(AmbientCredentials.readKey(connection, total: 2, keychain: false)?.from == "key file", "key file per connection")
        let info = HubHTTP.parseInfo(Data(#"{"protocol":"ambient/1","name":"Hub","key":"reader","reader":"me","sources":["a"]}"#.utf8))
        expect(info?.name == "Hub" && info?.sources == ["a"] && info?.keyKind == "reader", "info parsed")
        expect(HubHTTP.parseInfo(Data(#"{"name":"not a hub"}"#.utf8)) == nil, "non-hub info rejected")
        var settings = AmbientSettings()
        let publishInfo = HubInfo(name: "Hub", keyKind: "publish", reader: nil, sources: [], docs: nil, protocolVersion: "ambient/1")
        let base = URL(string: "https://h.example/v1")!
        if case .success = AmbientCommands.adopt(result: .success(publishInfo), base: base, key: "k", name: "", sources: [],
                                                 settings: &settings) {
            expect(false, "publish keys refused for reading")
        }
        expect(settings.connections.isEmpty, "nothing saved for a publish key")
        expect(HubHTTP.url(base, "/evt%201/dismiss").absoluteString.hasPrefix("https://h.example/v1/evt"), "paths are relative to the base")
        expect(HubHTTP.url(base, "", [URLQueryItem(name: "sticky", value: "open")]).absoluteString == "https://h.example/v1?sticky=open",
               "list is the base itself")
    }

    private static func plist() {
        let text = AmbientCommands.plist(binary: "/x/a&b/pager", logDirectory: "/tmp")
        let parsed = try? PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: Any]
        expect(parsed?["Label"] as? String == Ambient.label, "plist label")
        expect((parsed?["ProgramArguments"] as? [String]) == ["/x/a&b/pager", "ambient"], "plist arguments escaped")
        expect(((parsed?["KeepAlive"] as? [String: Any])?["SuccessfulExit"] as? Bool) == false, "restarts only on crash")
    }
}

// MARK: - ambient: idle check
//
// `pager ambient --idle-check` (and `make test`): the real app, every window
// off screen, with its own state directory and no hubs. It counts layout
// passes while nothing changes: with the log closed, with it open, and with
// lines in the overlay. A label that redraws itself on its own timer shows up
// here as passes that never stop, which is how the overlay once sat at 40% CPU.

@MainActor enum AmbientIdleCheck {
    static func isolate() {
        setenv("PAGER_AMBIENT_DIR", NSTemporaryDirectory() + "pager-idle-check-\(getpid())", 1)
        for name in [AmbientCredentials.urlVar, AmbientCredentials.readKeyVar, AmbientCredentials.hubVar] { unsetenv(name) }
    }

    static func run(_ app: AmbientApp) {
        Task { @MainActor in
            let ok = await check(app)
            try? FileManager.default.removeItem(atPath: AmbientPaths.directory)
            exit(ok ? 0 : 1)
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Events as they arrive, spaced out the way a busy stream is; with `age`, a backlog that old and older.
    private static func arrive(_ store: AmbientStore, _ count: Int, age: TimeInterval = 0) async {
        let sources = ["deploys", "github-acme", "stripe", "uptime"]
        for index in 0..<count {
            var event = AmbientEvent(id: AmbientEvent.localID(), source: sources[index % sources.count],
                                     text: "**check** event \(index) of \(count)")
            event.origin = "local"
            event.receivedAt = age == 0 ? Date() : Date().addingTimeInterval(-age - Double(count - index) * 37)
            store.ingest(event)
            if age == 0 { await pause(0.05) }
        }
    }

    private static func cpu() -> Double { Double(clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)) / 1e9 }

    /// Layout passes a second in the log and the overlay, and CPU, over `seconds` of nothing happening.
    private static func measure(_ app: AmbientApp, _ seconds: Double) async -> (log: Double, overlay: Double, cpu: Double) {
        func layouts() -> (Int, Int) {
            ((app.historyWindow?.contentView as? AmbientLayoutCounting)?.layouts ?? 0,
             (app.panel.contentView as? AmbientLayoutCounting)?.layouts ?? 0)
        }
        let (log, overlay) = layouts(), time = cpu(), start = Date()
        await pause(seconds)
        let elapsed = Date().timeIntervalSince(start), (log2, overlay2) = layouts()
        return (Double(log2 - log) / elapsed, Double(overlay2 - overlay) / elapsed, (cpu() - time) / elapsed * 100)
    }

    private static func check(_ app: AmbientApp) async -> Bool {
        let store = app.store
        var ok = true
        func report(_ name: String, _ m: (log: Double, overlay: Double, cpu: Double), log: Double, overlay: Double) {
            let pass = m.log <= log && m.overlay <= overlay
            ok = ok && pass
            print(String(format: "  %@  %@  log %5.1f layouts/s  overlay %5.1f layouts/s  cpu %4.1f%%", pass ? "ok  " : "FAIL",
                         name.padding(toLength: 10, withPad: " ", startingAt: 0), m.log, m.overlay, m.cpu))
        }
        // A log with a few hundred rows, none young enough to count seconds.
        store.pause(until: nil)
        await arrive(store, 300, age: 600)
        app.showHistory()
        await pause(0.5)
        app.historyWindow?.close()

        // Lines keep arriving while the log is closed: nothing should draw.
        await arrive(store, 20)
        await pause(1)
        report("log closed", await measure(app, 2), log: 0.5, overlay: 0.5)

        // The log open, with fresh events: their ages count seconds, one pass a second.
        app.showHistory()
        await arrive(store, 20)
        await pause(1)
        report("log open", await measure(app, 2), log: 2, overlay: 0.5)

        // Lines on screen, counting down: one pass a second for the overlay alone.
        app.historyWindow?.close()
        store.resume()
        await arrive(store, 6)
        await pause(1)
        report("overlay", await measure(app, 2), log: 0.5, overlay: 2)
        return ok
    }
}
