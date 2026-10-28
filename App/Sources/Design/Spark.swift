import SwiftUI

/// Spark, MAIPA-G's mascot: a speech bubble with a lit antenna. Drawn from the same shapes as the
/// app icon (design/icon.svg), in a 1024-point square, so it stays sharp at any size.
///
/// When its effect is on it floats gently and blinks now and then; while the AI works, its
/// antenna pulses faster and its eyes glance about.
struct Spark: View {
    enum Mood { case idle, working }

    var size: CGFloat
    var mood: Mood = .idle
    @Environment(\.theme) private var theme

    @State private var floating = false
    @State private var pulsing = false
    @State private var blink = false
    @State private var glance: CGFloat = 0

    var body: some View {
        let moves = theme.sparkMoves
        ZStack {
            // Glow behind the body.
            SparkBody()
                .fill(theme.accent.opacity(0.45))
                .blur(radius: size * 0.09)

            AntennaStem()
                .stroke(theme.accent, style: StrokeStyle(lineWidth: size * 26 / 1024, lineCap: .round))

            Circle()
                .fill(RadialGradient(colors: [.white, theme.accent.opacity(0.6), theme.accent.opacity(0)], center: .center, startRadius: 0, endRadius: size * 74 / 1024))
                .frame(width: size * 148 / 1024, height: size * 148 / 1024)
                .scaleEffect(moves && pulsing ? 1.18 : 0.92)
                .opacity(moves && pulsing ? 1 : 0.8)
                .position(x: size * 586 / 1024, y: size * 186 / 1024)
            Circle()
                .fill(.white)
                .frame(width: size * 48 / 1024, height: size * 48 / 1024)
                .position(x: size * 586 / 1024, y: size * 186 / 1024)

            SparkBody()
                .fill(LinearGradient(
                    colors: [Color.white.opacity(0.55).blendedOver(theme.accent), theme.accent, theme.partner],
                    startPoint: UnitPoint(x: 0.2, y: 0.05),
                    endPoint: UnitPoint(x: 0.8, y: 1)
                ))
            SparkBody()
                .fill(RadialGradient(colors: [Color.black.opacity(0.18), .clear], center: UnitPoint(x: 0.5, y: 0.95), startRadius: 0, endRadius: size * 0.55))

            Highlight()
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: size * 30 / 1024, lineCap: .round))

            eyes
                .offset(x: glance * size * 0.02)

            Smile()
                .stroke(Color(red: 0.04, green: 0.09, blue: 0.13), style: StrokeStyle(lineWidth: size * 16 / 1024, lineCap: .round))
        }
        .frame(width: size, height: size)
        .offset(y: moves && floating ? -size * 0.025 : size * 0.025)
        .accessibilityHidden(true)
        .onAppear { animate(moves) }
        .onChange(of: moves) { _, on in animate(on) }
        .onChange(of: mood) { _, _ in animate(moves) }
        .task(id: moves) { await blinkLoop(moves) }
    }

    private var eyes: some View {
        let ink = Color(red: 0.04, green: 0.09, blue: 0.13)
        return ZStack {
            Ellipse().fill(ink)
                .frame(width: size * 92 / 1024, height: size * 128 / 1024)
                .position(x: size * 424 / 1024, y: size * 566 / 1024)
            Ellipse().fill(ink)
                .frame(width: size * 92 / 1024, height: size * 128 / 1024)
                .position(x: size * 600 / 1024, y: size * 566 / 1024)
            Circle().fill(.white)
                .frame(width: size * 30 / 1024, height: size * 30 / 1024)
                .position(x: size * 440 / 1024, y: size * 540 / 1024)
            Circle().fill(.white)
                .frame(width: size * 30 / 1024, height: size * 30 / 1024)
                .position(x: size * 616 / 1024, y: size * 540 / 1024)
        }
        .scaleEffect(x: 1, y: blink ? 0.08 : 1, anchor: UnitPoint(x: 0.5, y: 566 / 1024))
    }

    private func animate(_ on: Bool) {
        guard on else {
            floating = false
            pulsing = false
            return
        }
        withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { floating = true }
        let pulse = mood == .working ? 0.55 : 1.6
        pulsing = false
        withAnimation(.easeInOut(duration: pulse).repeatForever(autoreverses: true)) { pulsing = true }
    }

    private func blinkLoop(_ on: Bool) async {
        guard on else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64.random(in: 2_800_000_000...6_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.07)) { blink = true }
            try? await Task.sleep(nanoseconds: 110_000_000)
            withAnimation(.easeOut(duration: 0.1)) { blink = false }
            if mood == .working, Bool.random() {
                withAnimation(.easeInOut(duration: 0.35)) { glance = Bool.random() ? 1 : -1 }
                try? await Task.sleep(nanoseconds: 900_000_000)
                withAnimation(.easeInOut(duration: 0.35)) { glance = 0 }
            }
        }
    }
}

// MARK: Shapes, in the icon's 1024-point square

private func point(_ x: CGFloat, _ y: CGFloat, in rect: CGRect) -> CGPoint {
    CGPoint(x: rect.minX + x / 1024 * rect.width, y: rect.minY + y / 1024 * rect.height)
}

struct SparkBody: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(512, 300, in: rect))
        path.addCurve(to: point(812, 578, in: rect), control1: point(690, 300, in: rect), control2: point(812, 420, in: rect))
        path.addCurve(to: point(512, 832, in: rect), control1: point(812, 736, in: rect), control2: point(690, 832, in: rect))
        path.addCurve(to: point(356, 806, in: rect), control1: point(452, 832, in: rect), control2: point(400, 824, in: rect))
        path.addCurve(to: point(236, 884, in: rect), control1: point(330, 840, in: rect), control2: point(290, 870, in: rect))
        path.addCurve(to: point(262, 778, in: rect), control1: point(262, 846, in: rect), control2: point(270, 808, in: rect))
        path.addCurve(to: point(212, 578, in: rect), control1: point(228, 724, in: rect), control2: point(212, 654, in: rect))
        path.addCurve(to: point(512, 300, in: rect), control1: point(212, 420, in: rect), control2: point(334, 300, in: rect))
        path.closeSubpath()
        return path
    }
}

private struct AntennaStem: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(512, 304, in: rect))
        path.addCurve(to: point(574, 196, in: rect), control1: point(512, 262, in: rect), control2: point(532, 220, in: rect))
        return path
    }
}

private struct Highlight: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(318, 418, in: rect))
        path.addCurve(to: point(504, 326, in: rect), control1: point(360, 360, in: rect), control2: point(432, 330, in: rect))
        return path
    }
}

private struct Smile: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: point(478, 668, in: rect))
        path.addCurve(to: point(546, 668, in: rect), control1: point(496, 684, in: rect), control2: point(528, 684, in: rect))
        return path
    }
}

extension Color {
    /// This colour laid over another, for a lighter tint of the accent that still matches it.
    func blendedOver(_ base: Color) -> Color {
        let top = UIColor(self), bottom = UIColor(base)
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        top.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        bottom.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return Color(red: tr * ta + br * (1 - ta), green: tg * ta + bg * (1 - ta), blue: tb * ta + bb * (1 - ta))
    }
}
