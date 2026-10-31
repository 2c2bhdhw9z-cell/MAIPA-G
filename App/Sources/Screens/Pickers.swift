import AgentCore
import SwiftUI

/// Modern AI Model Selector: searches all OpenRouter models (multi-word smart search across name,
/// maker, exact model ID, description, and capabilities), pins favourites, tracks recents, refreshes
/// live from OpenRouter, and supports entering any exact `provider/model` slug directly.
struct ModelPicker: View {
    var target: ComposerTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var filter: Filter = .all
    @State private var sort: SortOrder = .newest
    @State private var selectedMaker: String?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case pinned = "Pinned"
        case free = "Free"
        case thinks = "Thinking"
        case tools = "Tools"
        case vision = "Vision"
        case images = "Images"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .all: return "sparkles"
            case .pinned: return "star.fill"
            case .free: return "gift.fill"
            case .thinks: return "brain"
            case .tools: return "wrench.and.screwdriver.fill"
            case .vision: return "eye.fill"
            case .images: return "photo.fill"
            }
        }
    }

    enum SortOrder: String, CaseIterable, Identifiable {
        case newest = "Newest"
        case cheapest = "Cheapest"
        case context = "Largest context"
        case name = "Name (A–Z)"
        var id: String { rawValue }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var catalog: [ModelInfo] {
        app.openRouter.allSelectableModels.isEmpty ? app.openRouter.models : app.openRouter.allSelectableModels
    }

    var body: some View {
        let current = app.model(for: target)
        VStack(spacing: 0) {
            headerBar
            searchAndFiltersBar

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if trimmedQuery.isEmpty && filter == .all && selectedMaker == nil {
                        smartModesSection(current: current)
                        pinnedAndRecentSection(current: current)
                    }

                    if let customSlug = directSlugCandidate {
                        customSlugCard(slug: customSlug, current: current)
                    }

                    resultsSection(current: current)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Theme.background.ignoresSafeArea())
        .presentationDragIndicator(.visible)
        .task {
            await app.openRouter.loadModels()
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose an AI")
                    .font(.rounded(.title3, weight: .bold))
                HStack(spacing: 6) {
                    Text(catalog.isEmpty ? "Loading AI catalog…" : "\(catalog.count) models available")
                    if let left = app.openRouter.freeRequestsLeft {
                        Text("· \(left) free left today")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button {
                Haptics.selection()
                Task { await app.openRouter.loadModels(force: true) }
            } label: {
                Group {
                    if app.openRouter.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .frame(width: 34, height: 34)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh OpenRouter models")

            Menu {
                Picker("Sort models", selection: $sort) {
                    ForEach(SortOrder.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                if !makers.isEmpty {
                    Divider()
                    Button(selectedMaker == nil ? "✓ All makers" : "All makers") {
                        selectedMaker = nil
                    }
                    ForEach(makers.prefix(24), id: \.self) { maker in
                        Button(selectedMaker == maker ? "✓ \(maker)" : maker) {
                            selectedMaker = selectedMaker == maker ? nil : maker
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selectedMaker != nil ? theme.accent : .primary)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .accessibilityLabel("Sort and filter by maker")

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 34, height: 34)
                    .background(Theme.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Theme.stroke))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    private var searchAndFiltersBar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondaryText)
                TextField("Search all models, makers, or exact IDs…", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke))
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    if let maker = selectedMaker {
                        Button {
                            selectedMaker = nil
                        } label: {
                            HStack(spacing: 4) {
                                Text(maker)
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(theme.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(Filter.allCases) { chip in
                        let isSelected = filter == chip
                        Button {
                            filter = (filter == chip && chip != .all) ? .all : chip
                            Haptics.selection()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: chip.icon)
                                    .font(.caption2)
                                Text(chip.rawValue)
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(isSelected ? .white : .primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(isSelected ? theme.accent : Theme.surface, in: Capsule())
                            .overlay(Capsule().strokeBorder(isSelected ? Color.clear : Theme.stroke))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            Divider().opacity(0.5)
        }
    }

    private func smartModesSection(current: ModelChoice) -> some View {
        HStack(spacing: 10) {
            smartModeTile(
                choice: .auto,
                title: "Auto",
                subtitle: app.openRouter.hasOpenRouterKey
                    ? (app.openRouter.accountState.paidAllowed() ? "Best AI per task" : "Auto (free tier)")
                    : "Best connected AI",
                icon: "wand.and.stars",
                current: current
            )
            if app.openRouter.hasOpenRouterKey || app.openRouter.readyExternalProviders.isEmpty {
                smartModeTile(
                    choice: .free,
                    title: "Free AIs",
                    subtitle: "$0 · OpenRouter router",
                    icon: "gift.fill",
                    current: current
                )
            }
        }
    }

    private func smartModeTile(choice: ModelChoice, title: String, subtitle: String, icon: String, current: ModelChoice) -> some View {
        let selected = current == choice
        return Button {
            select(choice)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.accent)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(theme.accent)
                    }
                }
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(selected ? theme.accent : Theme.stroke, lineWidth: selected ? 1.6 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func pinnedAndRecentSection(current: ModelChoice) -> some View {
        let pinned = app.openRouter.pinnedModelIDs.compactMap { app.openRouter.modelsByID[$0] }
        let recents = app.openRouter.recentModelIDs
            .filter { !app.openRouter.pinnedModelIDs.contains($0) }
            .compactMap { app.openRouter.modelsByID[$0] }
            .prefix(4)

        if !pinned.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Pinned", count: pinned.count, icon: "star.fill")
                ForEach(pinned) { model in
                    modelCard(model, current: current)
                }
            }
        }
        if !recents.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Recent", count: recents.count, icon: "clock")
                ForEach(Array(recents)) { model in
                    modelCard(model, current: current)
                }
            }
        }
    }

    private var directSlugCandidate: String? {
        let q = trimmedQuery
        guard q.contains("/"), !q.contains(" "), q.count >= 4 else { return nil }
        if catalog.contains(where: { $0.id.caseInsensitiveCompare(q) == .orderedSame }) {
            return nil
        }
        return q
    }

    private func customSlugCard(slug: String, current: ModelChoice) -> some View {
        Button {
            select(.model(slug))
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title3)
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use exact OpenRouter ID")
                        .font(.subheadline.weight(.semibold))
                    Text(slug)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                if current == .model(slug) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.accent)
                } else {
                    Image(systemName: "arrow.right.circle").foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.accent.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func resultsSection(current: ModelChoice) -> some View {
        let matches = matchingModels
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionHeader(resultsTitle, count: matches.count, icon: nil)
                Spacer()
                Text(sort.rawValue)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
            }

            if catalog.isEmpty && app.openRouter.isLoadingModels {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading full OpenRouter model catalog…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else if matches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No models matched \"\(trimmedQuery.isEmpty ? filter.rawValue : trimmedQuery)\".")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        if filter != .all || selectedMaker != nil {
                            Button("Show all \(catalog.count) models") {
                                filter = .all
                                selectedMaker = nil
                            }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Refresh from OpenRouter") {
                            Task { await app.openRouter.loadModels(force: true) }
                        }
                        .font(.caption.weight(.semibold))
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
            } else {
                ForEach(matches) { model in
                    modelCard(model, current: current)
                }
            }
        }
    }

    private var resultsTitle: String {
        if !trimmedQuery.isEmpty { return "Search results" }
        if let maker = selectedMaker { return maker }
        switch filter {
        case .all: return "All models"
        case .pinned: return "Pinned models"
        case .free: return "Free models"
        case .thinks: return "Thinking / reasoning models"
        case .tools: return "Tool & repo-capable models"
        case .vision: return "Vision / image-reading models"
        case .images: return "Image-generating models"
        }
    }

    private func sectionHeader(_ title: String, count: Int, icon: String?) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(theme.accent)
            }
            Text("\(title) (\(count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.secondaryText)
        }
    }

    private var makers: [String] {
        var counts: [String: Int] = [:]
        for model in catalog {
            counts[model.maker, default: 0] += 1
        }
        return counts.keys.sorted { (counts[$0] ?? 0) != (counts[$1] ?? 0) ? (counts[$0] ?? 0) > (counts[$1] ?? 0) : $0 < $1 }
    }

    private var matchingModels: [ModelInfo] {
        let q = trimmedQuery.lowercased()
        let tokens = q.split(whereSeparator: \.isWhitespace).map(String.init)
        var scored: [(score: Int, model: ModelInfo)] = []
        scored.reserveCapacity(catalog.count)

        for model in catalog {
            if let selectedMaker, model.maker != selectedMaker { continue }
            // When actively typing a search query and filter == .pinned, don't trap the user in an empty pinned view.
            let activeFilter = (!tokens.isEmpty && filter == .pinned) ? .all : filter
            switch activeFilter {
            case .all: break
            case .pinned: if !app.openRouter.isPinned(model.id) { continue }
            case .free: if !model.isFree { continue }
            case .thinks: if model.thinkingLevels.isEmpty { continue }
            case .tools: if !model.supportsTools { continue }
            case .vision: if !model.acceptsImages { continue }
            case .images: if !model.generatesImages { continue }
            }

            if tokens.isEmpty {
                scored.append((0, model))
                continue
            }

            let idLower = model.id.lowercased()
            let nameLower = model.name.lowercased()
            let shortLower = model.shortName.lowercased()
            let makerLower = model.maker.lowercased()
            let summaryLower = model.summary?.lowercased() ?? ""
            let capabilityTags = [
                model.isFree ? "free" : "",
                !model.thinkingLevels.isEmpty ? "thinking reasoning" : "",
                model.supportsTools ? "tools agent" : "",
                model.acceptsImages ? "vision image multimodal" : "",
                model.generatesImages ? "image generation draw" : ""
            ].joined(separator: " ")
            let haystack = "\(nameLower) \(idLower) \(makerLower) \(capabilityTags) \(summaryLower)"
            let compactHaystack = haystack.filter { $0.isLetter || $0.isNumber }

            var matchedAll = true
            var score = 0
            for token in tokens {
                let compactToken = token.filter { $0.isLetter || $0.isNumber }
                if shortLower == token || idLower == token {
                    score += 120
                } else if shortLower.hasPrefix(token) || idLower.hasPrefix(token) {
                    score += 70
                } else if nameLower.contains(token) || idLower.contains(token) {
                    score += 45
                } else if makerLower.contains(token) {
                    score += 30
                } else if haystack.contains(token) || (!compactToken.isEmpty && compactHaystack.contains(compactToken)) {
                    score += 12
                } else {
                    matchedAll = false
                    break
                }
            }
            if matchedAll {
                if app.openRouter.isPinned(model.id) { score += 15 }
                scored.append((score, model))
            }
        }

        return scored.sorted { lhs, rhs in
            if !tokens.isEmpty, lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            switch sort {
            case .newest:
                let ld = lhs.model.created ?? .distantPast
                let rd = rhs.model.created ?? .distantPast
                if ld != rd { return ld > rd }
                return lhs.model.shortName < rhs.model.shortName
            case .cheapest:
                let lp = (lhs.model.promptPrice ?? 999) + (lhs.model.completionPrice ?? 999)
                let rp = (rhs.model.promptPrice ?? 999) + (rhs.model.completionPrice ?? 999)
                if lp != rp { return lp < rp }
                return lhs.model.shortName < rhs.model.shortName
            case .context:
                let lc = lhs.model.contextLength ?? 0
                let rc = rhs.model.contextLength ?? 0
                if lc != rc { return lc > rc }
                return lhs.model.shortName < rhs.model.shortName
            case .name:
                return lhs.model.shortName.localizedCaseInsensitiveCompare(rhs.model.shortName) == .orderedAscending
            }
        }.map(\.model)
    }

    private func select(_ choice: ModelChoice) {
        app.openRouter.recordRecent(choice)
        app.choose(model: choice, for: target)
        Haptics.selection()
        dismiss()
    }

    private func providerIconAsset(for modelID: String) -> String? {
        if let decoded = AIProviderModelID.decode(modelID) {
            return AIProviderPreset.matching(decoded.providerID)?.assetName
        }
        return "ProviderOpenRouter"
    }

    private func modelCard(_ model: ModelInfo, current: ModelChoice) -> some View {
        let isSelected = current == .model(model.id)
        let isPinned = app.openRouter.isPinned(model.id)
        let cantReadRepo = app.repo(for: target) != nil && !model.supportsTools

        return HStack(spacing: 10) {
            Button {
                select(.model(model.id))
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .center, spacing: 6) {
                        AIProviderIcon(
                            assetName: providerIconAsset(for: model.id),
                            fallbackTitle: model.maker,
                            size: 18
                        )

                        Text(model.maker)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(theme.accent.opacity(0.12), in: Capsule())

                        Text(model.shortName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(theme.accent)
                        }
                    }

                    Text(AIProviderModelID.rawModelID(model.id))
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)

                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        badge(text: price(model), highlight: model.isFree)
                        if !model.isFree, let cached = model.cacheReadPrice, cached > 0 {
                            badge(text: "Cache \(perMillionText(cached))", icon: "bolt.fill", highlight: true)
                        }
                        if let context = model.contextLength {
                            badge(text: "\(Self.tokens(context)) ctx")
                        }
                        if let maxOut = model.maxCompletionTokens, maxOut >= 16_000 {
                            badge(text: "\(Self.tokens(maxOut)) out")
                        }
                        if model.isPureImageModel {
                            badge(text: "Image gen only", icon: "paintbrush.fill", highlight: true)
                        } else {
                            if !model.thinkingLevels.isEmpty {
                                badge(text: "Thinks", icon: "brain")
                            }
                            if model.supportsTools {
                                badge(text: "Tools", icon: "wrench.and.screwdriver")
                            } else {
                                badge(text: "Chat only · No tools", icon: "bubble.left")
                            }
                            if model.acceptsImages {
                                badge(text: "Vision", icon: "eye")
                            }
                            if model.generatesImages {
                                badge(text: "Image", icon: "photo")
                            }
                        }
                    }

                    if model.isPureImageModel {
                        Text("Generates pictures directly from your prompt (no chat or repo tools)")
                            .font(.caption2)
                            .foregroundStyle(theme.accent)
                    } else if cantReadRepo {
                        Text("No tool support — attach no repo or pick a Tools model for repo edits")
                            .font(.caption2)
                            .foregroundStyle(Theme.danger)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                app.openRouter.togglePin(model.id)
                Haptics.selection()
            } label: {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(.subheadline)
                    .foregroundStyle(isPinned ? .yellow : Theme.secondaryText.opacity(0.65))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? "Unpin \(model.shortName)" : "Pin \(model.shortName)")
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? theme.accent : Theme.stroke, lineWidth: isSelected ? 1.6 : 1)
        )
    }

    private func badge(text: String, icon: String? = nil, highlight: Bool = false) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.medium))
        }
        .foregroundStyle(highlight ? .green : Theme.secondaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(highlight ? Color.green.opacity(0.12) : Theme.raised, in: Capsule())
    }

    /// "128K", "1M", "1.5M": how much a model can read at once.
    static func tokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            let millions = Double(count) / 1_000_000
            let text = String(format: "%.1f", millions)
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "M"
        }
        return "\(max(1, count / 1000))K"
    }

    private func perMillionText(_ perToken: Double) -> String {
        let m = perToken * 1_000_000
        if m >= 1 { return String(format: "$%.2f/M", m).replacingOccurrences(of: ".00", with: "") }
        if m >= 0.01 { return String(format: "$%.2f/M", m) }
        return String(format: "$%.3f/M", m)
    }

    /// Dollars per million tokens (about 750,000 words), for reading and for writing.
    private func price(_ model: ModelInfo) -> String {
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
}

/// Choose the repo for a chat.
struct RepoPicker: View {
    var target: ComposerTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.theme) private var theme
    @State private var query = ""

    var body: some View {
        let current = app.repo(for: target)
        NavigationStack {
            List {
                Section {
                    Button {
                        app.choose(repo: nil, for: target)
                        dismiss()
                    } label: {
                        HStack {
                            Label("No repo", systemImage: "bubble.left")
                            Spacer()
                            if current == nil { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    ForEach(filtered) { repo in
                        Button {
                            app.choose(repo: repo, for: target)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: repo.isPrivate ? "lock" : "chevron.left.forwardslash.chevron.right")
                                    .foregroundStyle(Theme.secondaryText)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(repo.ownerLogin == app.github.login ? repo.name : repo.fullName).font(.body)
                                    HStack(spacing: 6) {
                                        if let language = repo.language { Text(language) }
                                        if let pushed = repo.pushedAt { Text("updated \(pushed.friendlyAgo)") }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                                }
                                Spacer()
                                if current?.ref == repo.ref { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if app.github.isLoadingRepos, app.github.repos.isEmpty {
                        HStack { ProgressView(); Text("Getting your repos…").foregroundStyle(Theme.secondaryText) }
                    }
                    if let error = app.github.reposError {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                } footer: {
                    if let url = app.github.installationSettingsURL {
                        Button("Missing a repo? Let MAIPA-G into more of them") { openURL(url) }
                            .font(.footnote)
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search repos")
            .refreshable { await app.github.loadRepos() }
            .navigationTitle("Choose a repo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await app.github.loadRepos() }
        }
        .presentationDragIndicator(.visible)
    }

    private var filtered: [GitHubRepo] {
        let repos = app.github.repos.filter { $0.name != DataRepoSync.repoName }
        guard !query.isEmpty else { return repos }
        return repos.filter { $0.fullName.localizedCaseInsensitiveContains(query) || ($0.summary ?? "").localizedCaseInsensitiveContains(query) }
    }
}

/// Choose the branch for a chat's repo.
struct BranchPicker: View {
    var target: ComposerTarget
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var query = ""
    @State private var branches: [GitHubBranch] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        let repo = app.repo(for: target)
        NavigationStack {
            List {
                if let repo {
                    ForEach(filtered(repo)) { branch in
                        Button {
                            app.choose(branch: branch.name, for: target)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.secondaryText)
                                Text(branch.name)
                                if branch.name == repo.defaultBranch {
                                    Text("default")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(theme.accent.opacity(0.18), in: Capsule())
                                }
                                Spacer()
                                if repo.branch == branch.name { Image(systemName: "checkmark").foregroundStyle(theme.accent) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if loading { HStack { ProgressView(); Text("Getting branches…").foregroundStyle(Theme.secondaryText) } }
                    if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                } else {
                    Text("Choose a repo first.").foregroundStyle(Theme.secondaryText)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search branches")
            .navigationTitle(repo?.ref.name ?? "Branches")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load(repo) }
            .refreshable { await load(repo, refresh: true) }
        }
        .presentationDragIndicator(.visible)
    }

    private func load(_ repo: ChatRepo?, refresh: Bool = false) async {
        guard let repo else { loading = false; return }
        loading = true
        defer { loading = false }
        do {
            branches = try await app.github.branches(of: repo.ref, refresh: refresh)
            error = nil
        } catch {
            self.error = app.github.describe(error)
        }
    }

    private func filtered(_ repo: ChatRepo) -> [GitHubBranch] {
        let sorted = branches.sorted { a, b in
            if a.name == repo.defaultBranch { return true }
            if b.name == repo.defaultBranch { return false }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}
