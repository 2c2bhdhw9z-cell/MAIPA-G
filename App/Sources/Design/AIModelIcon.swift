import SwiftUI
import AgentCore

/// Bundled model-brand artwork. Inherits the caller's foreground style in light and dark mode.
/// Use `.accessibilityHidden(true)` when an adjacent label already identifies the model.
struct AIModelIcon: View {
    let modelID: String
    let size: CGFloat

    init(modelID: String, size: CGFloat = 20) {
        self.modelID = modelID
        self.size = size
    }

    var body: some View {
        let brand = AIModelBrand(modelID: modelID)
        Group {
            if let assetName = brand.assetName {
                Image(assetName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
            } else if brand == .automatic {
                Image(systemName: "wand.and.stars")
                    .resizable()
                    .scaledToFit()
            } else if brand == .free {
                Image(systemName: "gift")
                    .resizable()
                    .scaledToFit()
            } else {
                Text(AIModelBrand.initials(for: modelID))
                    .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(brand == .unknown ? (modelID.isEmpty ? "Unknown model" : modelID) : brand.displayName)
    }
}
