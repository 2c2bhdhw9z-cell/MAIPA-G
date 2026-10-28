import SwiftUI

/// Soft pools of the accent colours drifting slowly behind the home screen. Drawn with radial
/// gradients on a Canvas at 20 frames a second, which is smooth for something this slow and
/// light on the battery. Still when the effect is off.
struct GlowBackground: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let moving = theme.backgroundGlow
        TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !moving)) { timeline in
            Canvas { context, size in
                let t = moving ? timeline.date.timeIntervalSinceReferenceDate : 0
                let strength = colorScheme == .dark ? 0.30 : 0.22
                let blobs: [(Color, Double, Double, Double, Double, CGFloat)] = [
                    (theme.accent, 0.22, 0.20, 0.050, 0.0, 0.62),
                    (theme.partner, 0.82, 0.32, 0.037, 1.7, 0.55),
                    (theme.accent, 0.55, 0.88, 0.043, 3.1, 0.70),
                ]
                for (color, baseX, baseY, speed, phase, radius) in blobs {
                    let x = (baseX + 0.08 * sin(t * speed + phase)) * size.width
                    let y = (baseY + 0.06 * cos(t * speed * 1.3 + phase)) * size.height
                    let r = radius * max(size.width, size.height) * 0.6
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    context.fill(
                        Path(ellipseIn: rect),
                        with: .radialGradient(
                            Gradient(colors: [color.opacity(strength), color.opacity(0)]),
                            center: CGPoint(x: x, y: y),
                            startRadius: 0,
                            endRadius: r
                        )
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A band of light sweeping across text, for "Thinking…" and running tools.
struct Shimmer: ViewModifier {
    var active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.55), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.6)
                        .offset(x: phase * proxy.size.width * 1.6)
                        .blendMode(.plusLighter)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    phase = -1
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool) -> some View {
        modifier(Shimmer(active: active))
    }
}
