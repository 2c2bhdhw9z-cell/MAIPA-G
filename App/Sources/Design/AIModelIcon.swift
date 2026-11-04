import SwiftUI
import AgentCore

/// Colour logos keep their original artwork; monochrome logos adapt to the current appearance.
/// Use `.accessibilityHidden(true)` when an adjacent label already identifies the model.
struct AIModelIcon: View {
    let modelID: String
    let size: CGFloat
    let brand: AIModelBrand?

    init(modelID: String, size: CGFloat = 20, brand: AIModelBrand? = nil) {
        self.modelID = modelID
        self.size = size
        self.brand = brand
    }

    var body: some View {
        let brand = self.brand ?? AIModelBrand(modelID: modelID)
        Group {
            if let assetName = brand.assetName {
                // Only these bundled files are wholly monochrome; Kimi includes colour.
                if [AIModelBrand.openAI, .xAI, .xiaomi, .ai21, .ibm, .liquid, .reka, .nousResearch].contains(brand) {
                    Image(assetName)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                } else {
                    Image(assetName)
                        .renderingMode(.original)
                        .resizable()
                        .scaledToFit()
                        // Kimi's upstream mixed-colour art has black currentColor paths.
                        // A neutral backing keeps them visible without losing its blue accent.
                        .background(brand == .kimi ? Color.white : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 3))
                }
            } else if brand == .automatic {
                Image(systemName: "wand.and.stars")
                    .resizable()
                    .scaledToFit()
            } else if brand == .free {
                Image(systemName: "gift")
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear // No fabricated logo or initials for an unverified brand.
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(brand == .unknown ? (modelID.isEmpty ? "Unknown model" : modelID) : brand.displayName)
    }
}
