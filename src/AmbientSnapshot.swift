import AppKit
import SwiftUI

// MARK: - ambient: snapshots
//
// `pager ambient --snapshot out.png [--on page|white|black|mixed|<image>]`
// renders the overlay with the current settings and a few demo lines over a
// chosen background, without touching the screen. For checking legibility
// and for the README pictures. The window server's blur under the shade
// cannot be captured this way, so a snapshot shows the tint alone: the
// worst case, since the real overlay also frosts what is underneath.

enum AmbientSnapshot {
    struct Backdrop: View {
        let kind: String

        var body: some View {
            switch kind {
            case "white": Color.white
            case "black": Color.black
            case "mixed":
                LinearGradient(colors: [.white, Color(white: 0.85), .orange, .blue, Color(white: 0.1)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            case "page": page
            default:
                if let image = NSImage(contentsOfFile: (kind as NSString).expandingTildeInPath) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    page
                }
            }
        }

        /// The hard case: a light document full of grey text, the way most
        /// windows look under the top-right corner.
        private var page: some View {
            ZStack(alignment: .topLeading) {
                Color(white: 0.97)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(0..<40, id: \.self) { i in
                        Text(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit ", count: 3))
                            .font(.system(size: i % 9 == 0 ? 15 : 12, weight: i % 9 == 0 ? .semibold : .regular))
                            .foregroundColor(Color(white: i % 9 == 0 ? 0.1 : 0.35))
                            .lineLimit(1)
                    }
                }.padding(14)
            }
        }
    }

    @MainActor
    static func run(_ arguments: [String]) -> Int32 {
        guard let out = arguments.first, !out.hasPrefix("--") else {
            FileHandle.standardError.write(Data("usage: pager ambient --snapshot out.png [--on page|white|black|mixed|<image>] [--shade 0..1]\n".utf8))
            return 2
        }
        var kind = "page"
        if let i = arguments.firstIndex(of: "--on"), i + 1 < arguments.count { kind = arguments[i + 1] }
        var settings = AmbientSettings.load()
        if let i = arguments.firstIndex(of: "--shade"), i + 1 < arguments.count, let v = Double(arguments[i + 1]) {
            settings.shade = min(1, max(0, v))
        }
        settings.connections = []
        // Render without touching the real history, state or log.
        setenv("PAGER_AMBIENT_DIR", NSTemporaryDirectory() + "pager-snapshot-\(getpid())", 1)
        defer { try? FileManager.default.removeItem(atPath: AmbientPaths.directory) }
        let store = AmbientStore(settings: settings, state: AmbientState(), loadHistory: false)
        let now = Date()
        for (index, sample) in AmbientDemo.events().prefix(7).enumerated() {
            var event = sample
            event.id = "snap_\(index)"
            event.receivedAt = now.addingTimeInterval(-Double([2, 14, 75, 260, 700, 4000, 9000][index]))
            event.display = AmbientDisplay(lifetime: .sticky)
            store.ingest(event, record: false)
        }
        store.lines.sort { $0.anchor > $1.anchor }
        let width = settings.width + 12 + AmbientShadeGeometry.margin
        let size = CGSize(width: width + 80, height: 300)
        let backdrop = Backdrop(kind: kind).frame(width: size.width, height: size.height, alignment: .topLeading).clipped()
        let view = AmbientOverlay(store: store, blur: false)
            .frame(width: size.width, height: size.height)
            .background(backdrop)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("pager ambient: could not render\n".utf8))
            return 1
        }
        do { try png.write(to: URL(fileURLWithPath: out)) } catch {
            FileHandle.standardError.write(Data("pager ambient: \(error)\n".utf8)); return 1
        }
        print(out)
        return 0
    }

    /// The other windows, drawn offscreen through a real NSHostingView so
    /// native controls render too: `--snapshot-ui menu|history|settings|icon out.png`.
    @MainActor
    static func ui(_ arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: pager ambient --snapshot-ui menu|history|settings|icon out.png\n".utf8))
            return 2
        }
        let which = arguments[0], out = arguments[1]
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var settings = AmbientSettings.load()
        settings.connections = [AmbientConnection(id: "albastar", name: "albastar", url: "https://citadel.albastov.com/v1/events")]
        setenv("PAGER_AMBIENT_DIR", NSTemporaryDirectory() + "pager-snapshot-\(getpid())", 1)
        defer { try? FileManager.default.removeItem(atPath: AmbientPaths.directory) }
        let store = AmbientStore(settings: settings, state: AmbientState(), loadHistory: false)
        store.phases = ["albastar": "connected"]
        let now = Date()
        for (index, sample) in AmbientDemo.events().prefix(18).enumerated() {
            var event = sample
            event.id = "snap_\(index)"
            event.origin = "local"
            event.receivedAt = now.addingTimeInterval(-Double(index * index) * 97 - 3)
            if index == 4 { event.display = AmbientDisplay(lifetime: .sticky); event.url = "https://example.com" }
            if index == 6 { event.dismissedAt = now }
            store.history.insert(event, at: 0)
        }
        store.history.sort { ($0.receivedAt ?? now) > ($1.receivedAt ?? now) }
        if arguments.contains("--paused") { store.pause(until: now.addingTimeInterval(3600)) }
        let actions = AmbientMenuActions(pause: { _ in }, resume: {}, openLog: {}, openSettings: {},
                                         allowMiddleClick: {}, quit: {})
        let root: AnyView
        var size = NSSize(width: 340, height: 520)
        switch which {
        case "menu": root = AnyView(AmbientMenuView(store: store, actions: actions, middleClickNeedsPermission: true))
        case "history": root = AnyView(AmbientHistoryView(store: store)); size = NSSize(width: 720, height: 620)
        case "settings": root = AnyView(AmbientSettingsView(store: store)); size = NSSize(width: 400, height: 720)
        case "icon":
            root = AnyView(HStack(spacing: 30) {
                ForEach([false, true], id: \.self) { paused in
                    Image(nsImage: AmbientIcon.image(paused: paused, size: 18)).renderingMode(.template)
                        .resizable().interpolation(.none).frame(width: 144, height: 144)
                }
                VStack(spacing: 14) {
                    Image(nsImage: AmbientIcon.image(size: 18)).renderingMode(.template).foregroundColor(.white)
                    Image(nsImage: AmbientIcon.image(paused: true, size: 18)).renderingMode(.template).foregroundColor(.white)
                }
            }.padding(30).foregroundColor(.white).background(Color(white: 0.16)))
            size = NSSize(width: 420, height: 210)
        default: FileHandle.standardError.write(Data("unknown view \(which)\n".utf8)); return 2
        }
        let host = NSHostingView(rootView: root.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let fitting = host.fittingSize
        if which == "menu", fitting.height > 10 { size.height = fitting.height }
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AmbientTheme.nsInk
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        try? png.write(to: URL(fileURLWithPath: out))
        window.orderOut(nil)
        print(out)
        return 0
    }
}
