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
}
