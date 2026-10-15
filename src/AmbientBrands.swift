import AppKit
import SwiftUI

// MARK: - ambient: source marks
//
// A source called `github`, `github-albastar` or "GitHub" gets the GitHub mark
// and colour in the source column; `coolify` gets a shipping box in Coolify
// purple; a source nothing matches keeps plain dim text. Marks are Simple
// Icons (CC0) in assets/brands, fetched by tools/fetch-brands.sh. Your own:
// drop <slug>.svg or .png into ~/.pager/brands, or set an icon per source.

struct AmbientBrand: Equatable {
    /// A file in assets/brands or ~/.pager/brands, without extension.
    var mark: String?
    /// An SF Symbol, when there is no mark.
    var symbol: String?
    var color: String?

    init(mark: String? = nil, symbol: String? = nil, color: String? = nil) {
        self.mark = mark; self.symbol = symbol; self.color = color
    }

    static let known: [String: AmbientBrand] = [
        "github": .init(mark: "github", color: "#181717"),
        "gitlab": .init(mark: "gitlab", color: "#fc6d26"),
        "githubactions": .init(mark: "githubactions", color: "#2088ff"),
        "bitbucket": .init(mark: "bitbucket", color: "#0052cc"),
        "docker": .init(mark: "docker", color: "#2496ed"),
        "kubernetes": .init(mark: "kubernetes", color: "#326ce5"),
        "vercel": .init(mark: "vercel", color: "#000000"),
        "netlify": .init(mark: "netlify", color: "#00c7b7"),
        "cloudflare": .init(mark: "cloudflare", color: "#f38020"),
        "digitalocean": .init(mark: "digitalocean", color: "#0080ff"),
        "hetzner": .init(mark: "hetzner", color: "#d50c2d"),
        "stripe": .init(mark: "stripe", color: "#635bff"),
        "paypal": .init(mark: "paypal", color: "#002991"),
        "sentry": .init(mark: "sentry", color: "#362d59"),
        "grafana": .init(mark: "grafana", color: "#f46800"),
        "uptimekuma": .init(mark: "uptimekuma", color: "#5cdd8b"),
        "linear": .init(mark: "linear", color: "#5e6ad2"),
        "jira": .init(mark: "jira", color: "#0052cc"),
        "notion": .init(mark: "notion", color: "#000000"),
        "discord": .init(mark: "discord", color: "#5865f2"),
        "telegram": .init(mark: "telegram", color: "#26a5e4"),
        "gmail": .init(mark: "gmail", color: "#ea4335"),
        "googlecalendar": .init(mark: "googlecalendar", color: "#4285f4"),
        "apple": .init(mark: "apple", color: "#000000"),
        "postgresql": .init(mark: "postgresql", color: "#4169e1"),
        "redis": .init(mark: "redis", color: "#ff4438"),
        "npm": .init(mark: "npm", color: "#cb3837"),
        "coolify": .init(symbol: "shippingbox.fill", color: "#8a5cf6"),
        "uptime": .init(symbol: "waveform.path.ecg", color: "#5cdd8b"),
        "status": .init(symbol: "waveform.path.ecg", color: "#5cdd8b"),
        "backup": .init(symbol: "externaldrive.fill.badge.checkmark", color: "#9aa4b2"),
        "backups": .init(symbol: "externaldrive.fill.badge.checkmark", color: "#9aa4b2"),
        "ci": .init(symbol: "checkmark.seal.fill", color: "#9aa4b2"),
        "calendar": .init(mark: "googlecalendar", color: "#4285f4"),
        "mail": .init(symbol: "envelope.fill", color: "#9aa4b2"),
        "email": .init(symbol: "envelope.fill", color: "#9aa4b2"),
        "deploy": .init(symbol: "shippingbox.fill", color: "#9aa4b2"),
        "deploys": .init(symbol: "shippingbox.fill", color: "#9aa4b2"),
        "production": .init(symbol: "server.rack", color: "#9aa4b2"),
        "postgres": .init(mark: "postgresql", color: "#4169e1"),
        "actions": .init(mark: "githubactions", color: "#2088ff"),
    ]

    /// The first word of the slug or the name that is a known brand.
    /// `github-albastar` and "GitHub Actions" both resolve; the whole name
    /// squeezed together ("googlecalendar") is tried first.
    static func find(_ event: AmbientEvent) -> AmbientBrand? {
        let label = event.label.lowercased()
        let squeezed = label.filter { $0.isLetter || $0.isNumber }
        if let brand = known[squeezed] ?? custom(squeezed) { return brand }
        let words = (event.source.lowercased() + " " + label)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        for word in words { if let brand = known[word] ?? custom(word) { return brand } }
        return nil
    }

    static func monogram(_ label: String) -> AmbientBrand? {
        guard let letter = label.lowercased().first(where: { $0.isLetter || $0.isNumber }), letter.isASCII else { return nil }
        return AmbientBrand(symbol: "\(letter).circle.fill")
    }

    private static func custom(_ slug: String) -> AmbientBrand? {
        guard !slug.isEmpty, AmbientMarks.file(slug, userOnly: true) != nil else { return nil }
        return AmbientBrand(mark: slug)
    }

    /// Brand colours are chosen for white pages. On the overlay a near-black
    /// one (GitHub, Vercel, Notion, Apple) would vanish, so it turns light.
    static func readable(_ hex: String?) -> String? {
        guard let hex = AmbientRules.validHex(hex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xff), g = Double((value >> 8) & 0xff), b = Double(value & 0xff)
        let luma = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        if luma < 0.12 { return "#e6edf3" }
        if luma < 0.3 {
            func lift(_ c: Double) -> Int { Int(c + (255 - c) * 0.45) }
            return String(format: "#%02x%02x%02x", lift(r), lift(g), lift(b))
        }
        return hex
    }
}

enum AmbientMarks {
    private static var cache: [String: NSImage] = [:]

    static func file(_ name: String, userOnly: Bool = false) -> String? {
        var directories = [AmbientPaths.directory + "/brands"]
        if !userOnly { directories.append(Paths.repo.appendingPathComponent("assets/brands").path) }
        for directory in directories {
            for ext in ["svg", "png", "pdf"] {
                let path = "\(directory)/\(name).\(ext)"
                if FileManager.default.fileExists(atPath: path) { return path }
            }
        }
        return nil
    }

    /// Template images, so they take the brand colour. SVG needs the system's
    /// SVG support; where it is missing the caller falls back to a symbol.
    @MainActor
    static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let path = file(name), let image = NSImage(contentsOfFile: path), image.size.width > 0 else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}

/// The mark in the source column, sized to the text beside it.
struct AmbientMark: View {
    let brand: AmbientBrand
    let color: Color
    let size: Double

    var body: some View {
        Group {
            if let mark = brand.mark, let image = AmbientMarks.image(mark) {
                Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: brand.symbol ?? "circle.fill").resizable().aspectRatio(contentMode: .fit)
            }
        }
        .foregroundColor(color)
        .frame(width: size * 0.92, height: size * 0.92)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - size * 0.12 }
    }
}
