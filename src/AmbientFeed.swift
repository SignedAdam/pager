import Foundation
import Security

// MARK: - ambient: getting events in
//
// Two ways in. Locally, `pager event` writes one JSON line to a Unix socket
// the daemon owns. Remotely, the daemon holds one outbound SSE connection per
// hub: any server speaking the Ambient protocol (docs/protocol.md). The Mac
// never listens on the network.

// MARK: - the local socket

enum AmbientSocket {
    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    private static func setTimeout(_ fd: Int32, _ seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func readAll(_ fd: Int32, limit: Int = 256 * 1024, untilNewline: Bool) -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while out.count < limit {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            out.append(contentsOf: buffer[0..<n])
            if untilNewline, buffer[0..<n].contains(10) { break }
        }
        return out
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + sent, data.count - sent) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    /// One request, one reply, then the connection closes. Nil when nobody is listening.
    static func request(_ object: [String: Any], path: String = AmbientPaths.socket, timeout: Double = 3) -> [String: Any]? {
        guard var addr = address(path),
              let body = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        setTimeout(fd, timeout)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }
        guard writeAll(fd, body + Data([10])) else { return nil }
        shutdown(fd, SHUT_WR)
        let reply = readAll(fd, untilNewline: false)
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    /// The daemon's side. Each connection is read on a background thread and
    /// answered by `handler`, which the caller makes hop to the main thread.
    final class Server {
        let path: String
        private var fd: Int32 = -1
        private let handler: ([String: Any]) -> [String: Any]

        init(path: String = AmbientPaths.socket, handler: @escaping ([String: Any]) -> [String: Any]) {
            self.path = path
            self.handler = handler
        }

        func start() throws {
            unlink(path)
            guard var addr = AmbientSocket.address(path) else { throw AmbientError("socket path too long: \(path)") }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw AmbientError("socket() failed") }
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw AmbientError("cannot bind \(path): \(String(cString: strerror(errno)))") }
            chmod(path, 0o600)
            guard listen(fd, 16) == 0 else { throw AmbientError("listen failed") }
            let listener = fd
            let thread = Thread { [weak self] in
                while true {
                    let client = accept(listener, nil, nil)
                    if client < 0 { if errno == EINTR { continue }; break }
                    DispatchQueue.global(qos: .userInitiated).async { self?.serve(client) }
                }
            }
            thread.name = "pager.ambient.socket"
            thread.start()
        }

        private func serve(_ client: Int32) {
            defer { close(client) }
            AmbientSocket.setTimeout(client, 3)
            let data = AmbientSocket.readAll(client, untilNewline: true)
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let reply = handler(request)
            let body = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{}".utf8)
            _ = AmbientSocket.writeAll(client, body + Data([10]))
        }

        func stop() {
            if fd >= 0 { close(fd); fd = -1 }
            unlink(path)
        }
    }
}

struct AmbientError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

// MARK: - keys

/// Reader keys live in the Keychain, one item per connection id.
enum AmbientKeychain {
    static let service = "pager.ambient"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    /// An empty key deletes the item.
    @discardableResult
    static func save(_ key: String, for account: String) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !key.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrLabel as String] = "pager ambient: reader key for \(account)"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

enum AmbientCredentials {
    static let readKeyVar = "PAGER_AMBIENT_KEY"
    static let urlVar = "PAGER_AMBIENT_URL"
    static let publishKeyVar = "PAGER_AMBIENT_PUBLISH_KEY"
    static let hubVar = "PAGER_AMBIENT_HUB"

    static func env(_ name: String) -> String? {
        let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }

    /// `NAME=value` or `export NAME="value"` lines, the way shell env files look.
    static func fromFile(_ path: String, name: String) -> String? {
        guard !path.isEmpty,
              let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) else { return nil }
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "="), String(line[..<eq]) == name else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// The connections to run: the configured ones, or, with none configured,
    /// one called `default` from PAGER_AMBIENT_URL + PAGER_AMBIENT_KEY.
    static func connections(_ settings: AmbientSettings) -> [AmbientConnection] {
        if !settings.connections.isEmpty { return settings.connections }
        guard let url = env(urlVar), env(readKeyVar) != nil else { return [] }
        return [AmbientConnection(id: "default", name: "default", url: url)]
    }

    /// The reader key for one connection, and where it came from (for the
    /// settings window; the key itself is never logged). PAGER_AMBIENT_KEY only
    /// counts when there is a single connection, so it cannot leak to the wrong hub.
    static func readKey(_ connection: AmbientConnection, total: Int, keychain: Bool = true) -> (key: String, from: String)? {
        if total == 1, let key = env(readKeyVar) { return (key, "environment") }
        if let file = connection.keyFile, let key = fromFile(file, name: connection.keyVar ?? readKeyVar) {
            return (key, "key file")
        }
        if keychain, let key = AmbientKeychain.read(connection.id) { return (key, "Keychain") }
        return nil
    }
}

// MARK: - talking to a hub

struct HubInfo {
    var name: String
    var keyKind: String
    var reader: String?
    var sources: [String]
    var docs: String?
    var protocolVersion: String
}

enum HubHTTP {
    static func url(_ base: URL, _ path: String = "", _ query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path += path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    static func request(_ url: URL, key: String, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("pager/\(VERSION) ambient", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// For the command line, where blocking is what the user asked for.
    static func sync(_ request: URLRequest) -> (status: Int, data: Data, error: String?) {
        let done = DispatchSemaphore(value: 0)
        var out: (Int, Data, String?) = (0, Data(), nil)
        URLSession.shared.dataTask(with: request) { data, response, error in
            out = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data(), error?.localizedDescription)
            done.signal()
        }.resume()
        done.wait()
        return out
    }

    /// `{"code","message"}` (protocol v1), or whatever the body says.
    static func errorText(_ status: Int, _ data: Data) -> String {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let nested = object["error"] as? [String: Any]
            if let message = (object["message"] ?? nested?["message"]) as? String {
                let code = (object["code"] ?? nested?["code"]) as? String ?? ""
                return "HTTP \(status) \(code): \(message)"
            }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return "HTTP \(status)" + (text.isEmpty ? "" : " \(text)")
    }

    static func parseInfo(_ data: Data) -> HubInfo? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = object["protocol"] as? String, version.hasPrefix("ambient/") else { return nil }
        return HubInfo(name: object["name"] as? String ?? "hub", keyKind: object["key"] as? String ?? "",
                       reader: object["reader"] as? String, sources: object["sources"] as? [String] ?? [],
                       docs: object["docs"] as? String, protocolVersion: version)
    }

    /// GET {base}/info. Used by `connect` and the Settings window.
    static func info(base: URL, key: String) -> Result<HubInfo, AmbientError> {
        var request = request(url(base, "/info"), key: key)
        request.timeoutInterval = 10
        let (status, data, error) = sync(request)
        if status == 0 { return .failure(AmbientError("cannot reach \(base.absoluteString): \(error ?? "no response")")) }
        guard status == 200 else { return .failure(AmbientError(errorText(status, data))) }
        guard let info = parseInfo(data) else {
            return .failure(AmbientError("\(base.absoluteString)/info is not an Ambient hub (no \"protocol\":\"ambient/1\")"))
        }
        return .success(info)
    }
}

/// Thread-safe "when did we last hear anything", for the watchdog.
final class AmbientActivity {
    private let lock = NSLock()
    private var last = Date()
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    var since: TimeInterval { lock.lock(); defer { lock.unlock() }; return Date().timeIntervalSince(last) }
}

/// One resumable SSE connection to one hub, plus the few REST calls the
/// overlay needs. Everything it delivers is data handed to the callbacks.
@MainActor final class HubClient {
    enum Phase: Equatable {
        case idle, connecting, connected, waiting(TimeInterval), unauthorized, failed(String)
        var label: String {
            switch self {
            case .idle: return "idle"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .waiting(let s): return "reconnecting in \(Int(s.rounded()))s"
            case .unauthorized: return "key rejected"
            case .failed(let why): return why
            }
        }
    }

    let connection: AmbientConnection
    let base: URL
    private let key: String
    var cursor: String?
    var onEvent: (AmbientEvent) -> Void = { _ in }
    var onState: (String, Date?) -> Void = { _, _ in }
    var onStickies: ([AmbientEvent]) -> Void = { _ in }
    var onPhase: (Phase) -> Void = { _ in }
    var onCursor: (String) -> Void = { _ in }
    private(set) var phase = Phase.idle { didSet { if phase != oldValue { onPhase(phase) } } }
    private(set) var gaps = 0

    /// Silence for this long means the connection is dead even if TCP has not noticed.
    static var watchdog: TimeInterval = {
        Double(ProcessInfo.processInfo.environment["PAGER_AMBIENT_WATCHDOG"] ?? "") ?? 60
    }()

    private var loop: Task<Void, Never>?
    private var current: Task<ConnectionEnd, Never>?
    private var timer: Timer?
    private nonisolated let activity = AmbientActivity()
    private var attempt = 0
    private let streamSession: URLSession
    private let restSession: URLSession

    init(connection: AmbientConnection, base: URL, key: String) {
        self.connection = connection
        self.base = base
        self.key = key
        let stream = URLSessionConfiguration.ephemeral
        stream.timeoutIntervalForRequest = max(90, HubClient.watchdog + 30)
        stream.timeoutIntervalForResource = 7 * 86_400
        stream.requestCachePolicy = .reloadIgnoringLocalCacheData
        streamSession = URLSession(configuration: stream)
        let rest = URLSessionConfiguration.ephemeral
        rest.timeoutIntervalForRequest = 15
        restSession = URLSession(configuration: rest)
    }

    private var log: String { "hub \(connection.id)" }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in await self?.run() }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkWatchdog() }
        }
    }

    func stop() {
        loop?.cancel(); loop = nil
        current?.cancel(); current = nil
        timer?.invalidate(); timer = nil
        phase = .idle
    }

    /// After waking from sleep: drop whatever we had and go again, no waiting.
    func reconnectNow() {
        attempt = 0
        stop()
        start()
    }

    private func checkWatchdog() {
        guard phase == .connected, activity.since > HubClient.watchdog else { return }
        AmbientLog.write("\(log): no bytes for \(Int(activity.since))s, reconnecting")
        current?.cancel()
    }

    enum ConnectionEnd { case ended(gotData: Bool), unauthorized(String), failed(String) }

    private var sourceQuery: [URLQueryItem] {
        connection.sources.isEmpty ? [] : [URLQueryItem(name: "source", value: connection.sources.joined(separator: ","))]
    }

    private func run() async {
        while !Task.isCancelled {
            phase = .connecting
            await restoreStickies()
            let request = streamRequest()
            let task = Task { [weak self] () -> ConnectionEnd in
                guard let self else { return .failed("gone") }
                return await self.connect(request)
            }
            current = task
            let end = await task.value
            current = nil
            if Task.isCancelled { break }
            let delay: TimeInterval
            switch end {
            case .ended(let gotData):
                if gotData { attempt = 0 }
                delay = AmbientRules.backoff(attempt: attempt)
                attempt += 1
                phase = .waiting(delay)
                AmbientLog.write("\(log): stream ended, retry in \(String(format: "%.1f", delay))s")
            case .unauthorized(let why):
                // A revoked key will not come back by itself; knock rarely.
                delay = 300 * (0.8 + 0.4 * Double.random(in: 0...1))
                phase = .unauthorized
                AmbientLog.write("\(log): \(why), retry in \(Int(delay))s")
            case .failed(let why):
                delay = AmbientRules.backoff(attempt: attempt)
                attempt += 1
                phase = .waiting(delay)
                AmbientLog.write("\(log): \(why), retry in \(String(format: "%.1f", delay))s")
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func streamRequest() -> URLRequest {
        var request = HubHTTP.request(HubHTTP.url(base, "/stream", sourceQuery), key: key)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let cursor { request.setValue(cursor, forHTTPHeaderField: "Last-Event-ID") }
        return request
    }

    private nonisolated func connect(_ request: URLRequest) async -> ConnectionEnd {
        var gotData = false
        do {
            let (bytes, response) = try await streamSession.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                var body = Data()
                for try await byte in bytes { body.append(byte); if body.count > 2000 { break } }
                return .unauthorized(HubHTTP.errorText(status, body))
            }
            guard status == 200 else { return .failed("HTTP \(status)") }
            activity.touch()
            let resume = request.value(forHTTPHeaderField: "Last-Event-ID") ?? "-"
            await MainActor.run {
                self.phase = .connected
                AmbientLog.write("\(self.log): connected to \(self.base.absoluteString), resuming after \(resume)")
            }
            var parser = SSEParser()
            var line: [UInt8] = []
            line.reserveCapacity(1024)
            for try await byte in bytes {
                if byte != 10 { line.append(byte); continue }
                activity.touch()
                gotData = true
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if let frame = parser.feed(line: text) {
                    await MainActor.run { self.handle(frame) }
                }
            }
            return .ended(gotData: gotData)
        } catch is CancellationError {
            return .ended(gotData: gotData)
        } catch {
            if (error as? URLError)?.code == .cancelled { return .ended(gotData: gotData) }
            return .failed((error as? URLError).map { "network: \($0.localizedDescription)" } ?? "\(error)")
        }
    }

    private func handle(_ frame: SSEFrame) {
        switch frame.event {
        case "event", "message":
            guard var event = AmbientEvent.decode(Data(frame.data.utf8)) else {
                AmbientLog.write("\(log): unreadable event frame id=\(frame.id ?? "-")")
                return
            }
            event.origin = "hub"
            event.connection = connection.id
            if event.cursor == nil { event.cursor = frame.id }
            if let next = frame.id ?? event.cursor { cursor = next; onCursor(next) }
            onEvent(event)
        case "state":
            guard let object = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any],
                  let id = object["id"] as? String else { return }
            onState(id, (object["dismissed_at"] as? String).flatMap(AmbientTime.parse))
        case "gap":
            gaps += 1
            let gap = (try? JSONSerialization.jsonObject(with: Data(frame.data.utf8))) as? [String: Any]
            let missed = gap?["skipped"] ?? gap?["missed"]
            AmbientLog.write("\(log): gap, \(missed.map { "\($0)" } ?? "some") event(s) missed; they stay in the hub's history")
        default:
            break
        }
    }

    /// Stickies this reader has not dismissed, so they survive a restart and
    /// agree with the reader's other Macs after a reconnect (dismissals made
    /// while away are not replayed as frames).
    private func restoreStickies() async {
        let request = HubHTTP.request(HubHTTP.url(base, "", [URLQueryItem(name: "sticky", value: "open"),
                                                             URLQueryItem(name: "limit", value: "500")] + sourceQuery),
                                      key: key)
        guard let (data, response) = try? await restSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["events"] as? [Any] else { return }
        let events: [AmbientEvent] = list.compactMap { item in
            guard let data = try? JSONSerialization.data(withJSONObject: item),
                  var event = AmbientEvent.decode(data) else { return nil }
            event.origin = "hub"
            event.connection = connection.id
            return event
        }
        AmbientLog.write("\(log): \(events.count) open sticky event(s)")
        onStickies(events)
    }

    /// Fire and forget. Offline only means the reader's other Macs hear later.
    func setDismissed(_ id: String, _ dismissed: Bool) {
        let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(.init(charactersIn: "/"))) ?? id
        let request = HubHTTP.request(HubHTTP.url(base, "/\(escaped)/dismiss"), key: key,
                                      method: dismissed ? "POST" : "DELETE")
        let log = self.log
        Task {
            let status = ((try? await restSession.data(for: request))?.1 as? HTTPURLResponse)?.statusCode ?? 0
            AmbientLog.write("\(log): \(dismissed ? "dismiss" : "undismiss") \(id) -> \(status == 0 ? "offline" : String(status))")
        }
    }
}

// MARK: - publishing to a hub from the command line

enum HubPublish {
    /// POST {base}. Bounded retries with backoff, honouring Retry-After, then
    /// give up: the caller is usually a script that must not hang because a hub is down.
    static func send(base: URL, key: String, body: [String: Any]) -> (ok: Bool, status: Int, message: String) {
        var request = HubHTTP.request(base, key: key, method: "POST")
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        var last = (0, "no response")
        for attempt in 0..<3 {
            let (status, data, error) = HubHTTP.sync(request)
            if status == 200 || status == 201 { return (true, status, String(decoding: data, as: UTF8.self)) }
            last = (status, status == 0 ? (error ?? "network error") : HubHTTP.errorText(status, data))
            let retryable = status == 0 || status == 429 || status >= 500
            guard retryable, attempt < 2 else { break }
            Thread.sleep(forTimeInterval: min(5, AmbientRules.backoff(attempt: attempt)))
        }
        return (false, last.0, last.1)
    }
}
