import SwiftUI

/// A rounded "glass" panel: real Liquid Glass on iOS 26, frosted material before it.
struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat
    var interactive = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.stroke))
        }
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// A plain card on the page background.
    func card(cornerRadius: CGFloat = 18, padding: CGFloat = 14) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.stroke))
    }
}

/// A small capsule button, like the AI and repo pickers under the message box.
struct Chip: View {
    var title: String
    var systemImage: String?
    var showsChevron = false
    var tint: Color?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tint ?? .primary)
                }
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Theme.raised.opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The big accent button.
struct PrimaryButton: View {
    var title: String
    var systemImage: String?
    var isBusy = false
    var action: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView().tint(.black.opacity(0.8))
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(Color.black.opacity(0.85))
            .background(theme.gradient, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .opacity(isBusy ? 0.85 : 1)
    }
}

/// Lays children out left to right, wrapping onto new lines, like words in a paragraph. Used for
/// the answer buttons on the AI's questions.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0, x + size.width > width {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

extension Date {
    /// "just now", "5 min ago", "yesterday".
    var friendlyAgo: String {
        let seconds = Date().timeIntervalSince(self)
        if seconds < 50 { return "just now" }
        return formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

extension Double {
    /// Dollars for people: "$0.02", "$1.40", "under a cent".
    var dollars: String {
        if self > 0, self < 0.01 { return "under 1¢" }
        return formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
