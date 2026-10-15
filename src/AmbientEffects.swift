import SwiftUI

// MARK: - ambient: styled text and effects
//
// One line of formatted text: dim context, a message, and `**emphasis**` in
// the accent colour. Effects (blink, flash, highlight, wave, gradient) use
// SwiftUI's TextRenderer, which only exists on macOS 15. On 13 and 14 the same
// text is drawn without the effect, which is the default anyway.

extension Color {
    init?(hex: String?) {
        guard let hex = AmbientRules.validHex(hex), let value = Int(hex.dropFirst(), radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255, opacity: 1)
    }
}

enum AmbientText {
    /// The markdown subset, parsed once per line rather than per frame.
    static func runs(_ text: String) -> [(text: AttributedString, strong: Bool, italic: Bool, code: Bool)] {
        let attributed = (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            var piece = AttributedString(attributed[run.range])
            // Links are shown as text. Nothing on the overlay is clickable.
            piece.link = nil
            return (piece, intent.contains(.stronglyEmphasized), intent.contains(.emphasized), intent.contains(.code))
        }
    }

    /// `mark` tags the spans an effect applies to; on old systems it is identity.
    static func compose(text: String, context: String, color: Color, fontSize: Double,
                        target: EffectTarget, mark: (Text) -> Text) -> Text {
        var combined = Text(context).foregroundColor(.white.opacity(0.4)).font(.system(size: fontSize))
        for run in runs(text) {
            var fragment = Text(run.text)
                .font(.system(size: fontSize, design: run.code ? .monospaced : .default))
                .foregroundColor(run.strong ? color : .white.opacity(0.72))
            if run.strong { fragment = fragment.bold() }
            if run.italic { fragment = fragment.italic() }
            if target == .message || run.strong { fragment = mark(fragment) }
            combined = combined + fragment
        }
        return combined
    }
}

struct StyledMessage: View {
    let text: String
    var context: String = ""
    let color: Color
    let fontSize: Double
    var effect: TextEffect = .none
    var target: EffectTarget = .emphasis
    var period: Double = 2
    var startedAt: Date = Date()
    var lineLimit: Int = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var plain: some View {
        AmbientText.compose(text: text, context: context, color: color, fontSize: fontSize, target: target) { $0 }
            .lineLimit(lineLimit)
            .truncationMode(.tail)
    }

    var body: some View {
        if effect != .none && !reduceMotion {
            if #available(macOS 15, *) {
                EffectText(text: text, context: context, color: color, fontSize: fontSize, effect: effect,
                           target: target, period: period, startedAt: startedAt, lineLimit: lineLimit)
            } else {
                plain
            }
        } else {
            plain
        }
    }
}

@available(macOS 15, *)
private struct EffectSpan: TextAttribute {}

@available(macOS 15, *)
private struct EffectText: View {
    let text: String
    let context: String
    let color: Color
    let fontSize: Double
    let effect: TextEffect
    let target: EffectTarget
    let period: Double
    let startedAt: Date
    let lineLimit: Int

    var body: some View {
        let content = AmbientText.compose(text: text, context: context, color: color, fontSize: fontSize,
                                          target: target) { $0.customAttribute(EffectSpan()) }
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { clock in
            content
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .textRenderer(SpanRenderer(effect: effect, color: color,
                                           phase: max(0, clock.date.timeIntervalSince(startedAt)) / max(0.5, period)))
        }
    }
}

@available(macOS 15, *)
private struct SpanRenderer: TextRenderer {
    let effect: TextEffect
    let color: Color
    let phase: Double

    var displayPadding: EdgeInsets {
        effect == .wave ? EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0) : EdgeInsets()
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let cycle = phase.truncatingRemainder(dividingBy: 1)
        let pulse = (1 - cos(cycle * 2 * .pi)) / 2
        for line in layout {
            for run in line {
                guard run[EffectSpan.self] != nil else {
                    context.draw(run)
                    continue
                }
                var layer = context
                let bounds = run.typographicBounds.rect
                switch effect {
                case .none:
                    layer.draw(run)
                case .blink:
                    layer.opacity = cycle < 0.5 ? 1 : 0.15
                    layer.draw(run)
                case .flash:
                    layer.clipToLayer { $0.draw(run) }
                    layer.fill(Path(bounds), with: .color(color))
                    layer.opacity = pulse
                    layer.fill(Path(bounds), with: .color(.white))
                case .highlight:
                    layer.fill(Path(roundedRect: bounds.insetBy(dx: -2, dy: -1), cornerRadius: 2),
                               with: .color(color.opacity(0.05 + pulse * 0.5)))
                    layer.draw(run)
                case .wave:
                    for slice in run {
                        var glyph = context
                        let x = slice.typographicBounds.rect.minX
                        glyph.translateBy(x: 0, y: sin(cycle * 2 * .pi - x / 18) * 2)
                        glyph.draw(slice)
                    }
                case .gradient:
                    let span = max(80, bounds.width)
                    let start = bounds.minX - cycle * span
                    layer.clipToLayer { $0.draw(run) }
                    layer.fill(Path(bounds), with: .linearGradient(
                        Gradient(colors: [color, .cyan, .purple, color]),
                        startPoint: CGPoint(x: start, y: bounds.midY),
                        endPoint: CGPoint(x: start + span, y: bounds.midY), options: .repeat))
                }
            }
        }
    }
}
