import AgentCore
import SwiftUI

// MARK: - Model maker (the company that made the model, not the gateway routing it)

/// The real company behind a model (Anthropic, OpenAI, xAI…), as opposed to the gateway that routes it.
///
/// `ModelInfo.maker` reads the display-name prefix, which for OneProvider / SayGM / TeamoRouter / OmniRoute
/// models is the *gateway* ("TeamoRouter: Claude Sonnet 5.5" → "TeamoRouter"), so the picker derives the
/// maker from the raw model ID and short name instead. The gateway's logo is never used as a maker icon.
struct ModelMaker: Equatable, Sendable {
    let name: String
    /// A bundled logo in Assets.xcassets, when the app ships one for this maker.
    let assetName: String?
    /// SF Symbol shown when there is no bundled logo.
    let symbol: String

    static let fallbackSymbol = "cpu"
    static let routerSymbol = "arrow.triangle.branch"

    private struct Rule: Sendable {
        let name: String
        let slugs: [String]
        let keywords: [String]
        var asset: String? = nil
    }

    private static let rules: [Rule] = [
        Rule(name: "Anthropic", slugs: ["anthropic"], keywords: ["claude"]),
        Rule(name: "OpenAI", slugs: ["openai"], keywords: ["gpt", "chatgpt", "dall", "o1", "o3", "o4", "codex", "sora", "whisper"]),
        Rule(name: "xAI", slugs: ["x-ai", "xai"], keywords: ["grok"]),
        Rule(name: "DeepSeek", slugs: ["deepseek"], keywords: ["deepseek"]),
        Rule(name: "Google", slugs: ["google"], keywords: ["gemini", "gemma", "imagen", "palm", "veo"]),
        Rule(name: "Meta", slugs: ["meta-llama", "meta"], keywords: ["llama"]),
        Rule(name: "Mistral", slugs: ["mistralai", "mistral"], keywords: ["mistral", "mixtral", "codestral", "devstral", "magistral", "pixtral", "ministral"]),
        Rule(name: "Qwen", slugs: ["qwen", "alibaba"], keywords: ["qwen", "qwq"]),
        Rule(name: "Moonshot", slugs: ["moonshotai", "moonshot"], keywords: ["kimi"]),
        Rule(name: "Z.ai", slugs: ["z-ai", "zai", "zhipu", "thudm"], keywords: ["glm"]),
        Rule(name: "MiniMax", slugs: ["minimax"], keywords: ["minimax"]),
        Rule(name: "Microsoft", slugs: ["microsoft"], keywords: ["phi", "wizardlm"], asset: "IntegrationMicrosoft"),
        Rule(name: "Perplexity", slugs: ["perplexity"], keywords: ["sonar"], asset: "IntegrationPerplexity"),
        Rule(name: "Amazon", slugs: ["amazon"], keywords: ["nova"]),
        Rule(name: "Cohere", slugs: ["cohere"], keywords: ["command"]),
        Rule(name: "NVIDIA", slugs: ["nvidia"], keywords: ["nemotron"]),
        Rule(name: "Nous Research", slugs: ["nousresearch"], keywords: ["hermes"]),
    ]

    /// Derives the maker from the model's raw ID (provider prefix stripped) and short name.
    /// `catalogMaker` is `ModelInfo.maker`; it is only trusted when it is not the routing gateway's name.
    static func resolve(rawID: String, shortName: String, catalogMaker: String, providerName: String, isRouter: Bool) -> ModelMaker {
        let lowerID = rawID.lowercased()
        if isRouter || lowerID.hasPrefix("openrouter/") {
            return ModelMaker(name: "Router", assetName: nil, symbol: routerSymbol)
        }
        if let slash = lowerID.firstIndex(of: "/") {
            let slug = String(lowerID[..<slash])
            if let rule = rules.first(where: { $0.slugs.contains(slug) }) {
                return ModelMaker(rule)
            }
        }
        let tokens = (lowerID + " " + shortName.lowercased())
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        for rule in rules where rule.keywords.contains(where: { keyword in tokens.contains { matches(token: $0, keyword: keyword) } }) {
            return ModelMaker(rule)
        }
        if lowerID.contains("auto") && shortName.lowercased().contains("router") {
            return ModelMaker(name: "Router", assetName: nil, symbol: routerSymbol)
        }
        if let rule = rules.first(where: { $0.name.caseInsensitiveCompare(catalogMaker) == .orderedSame }) {
            return ModelMaker(rule)
        }
        let isGatewayName = catalogMaker.caseInsensitiveCompare(providerName) == .orderedSame
        return ModelMaker(name: isGatewayName ? "Other" : catalogMaker, assetName: nil, symbol: fallbackSymbol)
    }

    /// "gpt" matches "gpt", "gpt4o"; "claude" matches "claude", "claude3"; short keywords never match a longer word ("phi" ≠ "phind").
    private static func matches(token: String, keyword: String) -> Bool {
        if token == keyword { return true }
        guard token.hasPrefix(keyword) else { return false }
        if keyword.count >= 4 { return true }
        return token.dropFirst(keyword.count).first?.isNumber == true
    }

    private init(_ rule: Rule) {
        self.init(name: rule.name, assetName: rule.asset, symbol: Self.fallbackSymbol)
    }

    init(name: String, assetName: String?, symbol: String) {
        self.name = name
        self.assetName = assetName
        self.symbol = symbol
    }
}

// MARK: - Precomputed row data

/// Everything a picker row shows or searches, computed once when the catalog loads, so scrolling and typing
/// never re-run price formatting, token formatting, ID decoding, or string lowering per row per frame.
struct ModelRowData: Identifiable, Equatable, Sendable {
    let id: String
    let shortName: String
    let rawID: String
    let maker: ModelMaker
    /// The gateway routing the model ("OpenRouter", "TeamoRouter"…), shown as a tiny label.
    let providerName: String
    /// `ModelInfo.maker`, kept for the maker filter menu.
    let catalogMaker: String
    let summary: String?

    let priceText: String
    let cacheText: String?
    let contextText: String?
    let maxOutputText: String?
    /// The one caption line under the name: "$3/$15 · 200K ctx".
    let detailLine: String
    /// The full badge set, shown only in the detail sheet.
    let capabilityTags: [String]

    let isFree: Bool
    let thinks: Bool
    let supportsTools: Bool
    let acceptsImages: Bool
    let generatesImages: Bool
    let isPureImageModel: Bool

    // Search and sort keys.
    let idLower: String
    let nameLower: String
    let shortLower: String
    let makerLower: String
    let haystack: String
    let compactHaystack: String
    let sortName: String
    let created: Date
    let totalPrice: Double
    let context: Int

    init(model: ModelInfo, providerNames: [String: String]) {
        let providerID = AIProviderModelID.providerID(model.id)
        let providerName = providerID == "openrouter"
            ? "OpenRouter"
            : (providerNames[providerID] ?? AIProviderPreset.matching(providerID)?.name ?? providerID)
        let rawID = AIProviderModelID.rawModelID(model.id)
        let catalogMaker = model.maker
        let shortName = model.shortName
        let maker = ModelMaker.resolve(
            rawID: rawID,
            shortName: shortName,
            catalogMaker: catalogMaker,
            providerName: providerName,
            isRouter: model.isRouter
        )

        id = model.id
        self.shortName = shortName
        self.rawID = rawID
        self.maker = maker
        self.providerName = providerName
        self.catalogMaker = catalogMaker
        summary = model.summary

        isFree = model.isFree
        thinks = !model.thinkingLevels.isEmpty
        supportsTools = model.supportsTools
        acceptsImages = model.acceptsImages
        generatesImages = model.generatesImages
        isPureImageModel = model.isPureImageModel

        priceText = Self.price(model)
        if !model.isFree, let cached = model.cacheReadPrice, cached > 0 {
            cacheText = Self.perMillionText(cached)
        } else {
            cacheText = nil
        }
        contextText = model.contextLength.map { ModelInfo.formattedTokenCount($0) }
        maxOutputText = model.maxCompletionTokens.map { ModelInfo.formattedTokenCount($0) }

        var line = [priceText]
        if let contextText { line.append("\(contextText) ctx") }
        if isPureImageModel {
            line.append("Image gen only")
        } else if !supportsTools {
            line.append("No tools")
        }
        detailLine = line.joined(separator: " · ")

        var tags: [String] = []
        if isPureImageModel {
            tags.append("Image gen only")
        } else {
            if thinks { tags.append("Thinks") }
            tags.append(supportsTools ? "Tools" : "Chat only · No tools")
            if acceptsImages { tags.append("Vision") }
            if generatesImages { tags.append("Image") }
        }
        if isFree { tags.insert("Free", at: 0) }
        capabilityTags = tags

        idLower = model.id.lowercased()
        nameLower = model.name.lowercased()
        shortLower = shortName.lowercased()
        makerLower = "\(catalogMaker) \(maker.name) \(providerName)".lowercased()
        let capabilityWords = [
            isFree ? "free" : "",
            thinks ? "thinking reasoning" : "",
            supportsTools ? "tools agent" : "",
            acceptsImages ? "vision image multimodal" : "",
            generatesImages ? "image generation draw" : ""
        ].joined(separator: " ")
        haystack = "\(nameLower) \(idLower) \(makerLower) \(capabilityWords) \(model.summary?.lowercased() ?? "")"
        compactHaystack = haystack.filter { $0.isLetter || $0.isNumber }
        sortName = shortLower
        created = model.created ?? .distantPast
        totalPrice = (model.promptPrice ?? 999) + (model.completionPrice ?? 999)
        context = model.contextLength ?? 0
    }

    /// Dollars per million tokens (about 750,000 words), for reading and for writing.
    static func price(_ model: ModelInfo) -> String {
        if model.isFree { return "Free" }
        guard let input = model.promptPrice, let output = model.completionPrice else { return "Variable" }
        func dollars(_ perToken: Double) -> String {
            let perMillion = perToken * 1_000_000
            if perMillion == 0 { return "$0" }
            if perMillion < 0.01 { return "<$0.01" }
            if perMillion < 1, abs(perMillion * 100 - (perMillion * 100).rounded()) > 0.001 {
                return String(format: "$%.3f", perMillion)
            }
            let text = String(format: "%.2f", perMillion)
            return "$" + (text.hasSuffix(".00") ? String(text.dropLast(3)) : text)
        }
        return "\(dollars(input))/\(dollars(output))"
    }

    static func perMillionText(_ perToken: Double) -> String {
        let m = perToken * 1_000_000
        if m >= 1 { return String(format: "$%.2f/M", m).replacingOccurrences(of: ".00", with: "") }
        if m >= 0.01 { return String(format: "$%.2f/M", m) }
        return String(format: "$%.3f/M", m)
    }
}

// MARK: - Catalog index (built once per catalog load)

struct ModelPickerIndex: Sendable {
    private(set) var rows: [ModelRowData] = []
    private(set) var byID: [String: ModelRowData] = [:]
    /// `ModelInfo.maker` values, most models first, for the maker filter menu.
    private(set) var makers: [String] = []

    static let empty = ModelPickerIndex()

    init() {}

    init(catalog: [ModelInfo], providerNames: [String: String]) {
        rows = catalog.map { ModelRowData(model: $0, providerNames: providerNames) }
        byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for row in rows { counts[row.catalogMaker, default: 0] += 1 }
        makers = counts.keys.sorted { (counts[$0] ?? 0) != (counts[$1] ?? 0) ? (counts[$0] ?? 0) > (counts[$1] ?? 0) : $0 < $1 }
    }

    /// Same filters, scoring, and sort orders as before, run against precomputed lowercase fields.
    func matching(
        query: String,
        filter: ModelPicker.Filter,
        sort: ModelPicker.SortOrder,
        maker selectedMaker: String?,
        pinned: Set<String>
    ) -> [ModelRowData] {
        let tokens = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        // When actively typing a search query and filter == .pinned, don't trap the user in an empty pinned view.
        let activeFilter = (!tokens.isEmpty && filter == .pinned) ? .all : filter
        var scored: [(score: Int, row: ModelRowData)] = []
        scored.reserveCapacity(rows.count)

        for row in rows {
            if let selectedMaker, row.catalogMaker != selectedMaker { continue }
            // Exclude pure image-generation models from default chat model lists unless `Images` is active or searching by name.
            if activeFilter != .images, tokens.isEmpty, row.isPureImageModel { continue }
            switch activeFilter {
            case .all: break
            case .pinned: if !pinned.contains(row.id) { continue }
            case .free: if !row.isFree { continue }
            case .thinks: if !row.thinks { continue }
            case .tools: if !row.supportsTools { continue }
            case .vision: if !row.acceptsImages { continue }
            case .images: if !row.generatesImages { continue }
            }

            if tokens.isEmpty {
                scored.append((0, row))
                continue
            }

            var matchedAll = true
            var score = 0
            for token in tokens {
                let compactToken = token.filter { $0.isLetter || $0.isNumber }
                if row.shortLower == token || row.idLower == token {
                    score += 120
                } else if row.shortLower.hasPrefix(token) || row.idLower.hasPrefix(token) {
                    score += 70
                } else if row.nameLower.contains(token) || row.idLower.contains(token) {
                    score += 45
                } else if row.makerLower.contains(token) {
                    score += 30
                } else if row.haystack.contains(token) || (!compactToken.isEmpty && row.compactHaystack.contains(compactToken)) {
                    score += 12
                } else {
                    matchedAll = false
                    break
                }
            }
            if matchedAll {
                if pinned.contains(row.id) { score += 15 }
                scored.append((score, row))
            }
        }

        return scored.sorted { lhs, rhs in
            if !tokens.isEmpty, lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            switch sort {
            case .newest:
                if lhs.row.created != rhs.row.created { return lhs.row.created > rhs.row.created }
                return lhs.row.shortName < rhs.row.shortName
            case .cheapest:
                if lhs.row.totalPrice != rhs.row.totalPrice { return lhs.row.totalPrice < rhs.row.totalPrice }
                return lhs.row.shortName < rhs.row.shortName
            case .context:
                if lhs.row.context != rhs.row.context { return lhs.row.context > rhs.row.context }
                return lhs.row.shortName < rhs.row.shortName
            case .name:
                return lhs.row.sortName < rhs.row.sortName
            }
        }.map(\.row)
    }
}

// MARK: - Views

/// The maker's bundled logo, or a clean SF Symbol when the app has no logo for that maker.
struct MakerIcon: View {
    let maker: ModelMaker
    var size: CGFloat = 26
    @Environment(\.theme) private var theme

    var body: some View {
        if let assetName = maker.assetName {
            AIProviderIcon(assetName: assetName, fallbackTitle: maker.name, size: size)
        } else {
            Image(systemName: maker.symbol)
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: size, height: size)
                .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

/// A light, flat picker row: maker icon, "Maker · via Gateway" micro-label, name, one caption line.
/// Equatable so SwiftUI skips rows whose data, selection, and pin state did not change.
struct ModelRow: View, Equatable {
    let data: ModelRowData
    let isSelected: Bool
    let isPinned: Bool
    let showsRepoWarning: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onShowDetails: () -> Void
    @Environment(\.theme) private var theme

    nonisolated static func == (lhs: ModelRow, rhs: ModelRow) -> Bool {
        lhs.data == rhs.data
            && lhs.isSelected == rhs.isSelected
            && lhs.isPinned == rhs.isPinned
            && lhs.showsRepoWarning == rhs.showsRepoWarning
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    MakerIcon(maker: data.maker, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(data.maker.name)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(theme.accent)
                            Text("via \(data.providerName)")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.secondaryText.opacity(0.8))
                        }
                        .lineLimit(1)
                        Text(data.shortName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(data.detailLine)
                            .font(.caption2)
                            .foregroundStyle(data.isFree ? Color.green : Theme.secondaryText)
                            .lineLimit(1)
                        if showsRepoWarning {
                            Text("No tool support — pick a Tools model for repo edits")
                                .font(.caption2)
                                .foregroundStyle(Theme.danger)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onShowDetails) {
                Image(systemName: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText.opacity(0.65))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Details for \(data.shortName)")

            Button(action: onTogglePin) {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(.subheadline)
                    .foregroundStyle(isPinned ? .yellow : Theme.secondaryText.opacity(0.65))
                    .frame(width: 30, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Unpin \(data.shortName)" : "Pin \(data.shortName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            isSelected ? theme.accent.opacity(0.10) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

/// Everything the old badge strip showed (price, cache, context, max output, capabilities, gateway, exact ID).
struct ModelDetailSheet: View {
    let data: ModelRowData
    let isSelected: Bool
    let onSelect: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        MakerIcon(maker: data.maker, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(data.shortName)
                                .font(.headline)
                            Text("\(data.maker.name) · routed by \(data.providerName)")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    Text(data.rawID)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                        .textSelection(.enabled)
                }
                Section("Details") {
                    LabeledContent("Price (in/out per 1M)", value: data.priceText)
                    if let cacheText = data.cacheText {
                        LabeledContent("Cache read", value: cacheText)
                    }
                    if let contextText = data.contextText {
                        LabeledContent("Context", value: contextText)
                    }
                    if let maxOutputText = data.maxOutputText {
                        LabeledContent("Max output", value: maxOutputText)
                    }
                    LabeledContent("Provider", value: data.providerName)
                }
                Section("Can do") {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(data.capabilityTags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(tag == "Free" ? Color.green : Theme.secondaryText)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(tag == "Free" ? Color.green.opacity(0.12) : Theme.raised, in: Capsule())
                        }
                    }
                    if data.isPureImageModel {
                        Text("Generates pictures directly from your prompt (no chat or repo tools)")
                            .font(.caption)
                            .foregroundStyle(theme.accent)
                    }
                }
                if let summary = data.summary, !summary.isEmpty {
                    Section("About") {
                        Text(summary)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Model details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSelected ? "Selected" : "Use this AI") { onSelect() }
                        .disabled(isSelected)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
