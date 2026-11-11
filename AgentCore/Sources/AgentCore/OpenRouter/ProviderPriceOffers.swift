import Foundation

/// A gateway that charges more once a request's input passes a size (TeamoRouter's `context_tier_pricing`:
/// over 272K input tokens, input costs 2x and output 1.5x).
public struct ContextTierPricing: Codable, Sendable, Hashable {
    public var thresholdTokens: Int
    public var inputMultiplier: Double
    public var outputMultiplier: Double

    public init(thresholdTokens: Int, inputMultiplier: Double, outputMultiplier: Double) {
        self.thresholdTokens = thresholdTokens
        self.inputMultiplier = inputMultiplier
        self.outputMultiplier = outputMultiplier
    }

    static func parse(_ json: JSONValue?) -> ContextTierPricing? {
        guard let json, let threshold = json["threshold_tokens"]?.intValue, threshold > 0 else { return nil }
        let input = json["input_multiplier"]?.doubleValue ?? 1
        let output = json["output_multiplier"]?.doubleValue ?? 1
        guard input > 0, output > 0, input != 1 || output != 1 else { return nil }
        return ContextTierPricing(thresholdTokens: threshold, inputMultiplier: input, outputMultiplier: output)
    }
}

/// A limited offer the signed-in account has claimed (TeamoRouter's "Surprise price"), applied on top of
/// the gateway's regular price. While it lasts the model's `promptPrice`/`completionPrice` are the offer
/// price and the regular prices are kept here, so the picker can strike them through and the app can
/// go back to them once the offer ends or its quota is used up.
public struct PriceOffer: Codable, Sendable, Hashable {
    public var key: String
    public var name: String
    /// Fraction of the list price charged (0.1 = 90% off list).
    public var listRate: Double
    public var quotaUSD: Double?
    public var remainingUSD: Double?
    public var endsAt: Date?
    public var regularPromptPrice: Double?
    public var regularCompletionPrice: Double?
    public var regularCacheReadPrice: Double?
    public var regularCacheWritePrice: Double?

    public init(
        key: String,
        name: String,
        listRate: Double,
        quotaUSD: Double? = nil,
        remainingUSD: Double? = nil,
        endsAt: Date? = nil,
        regularPromptPrice: Double? = nil,
        regularCompletionPrice: Double? = nil,
        regularCacheReadPrice: Double? = nil,
        regularCacheWritePrice: Double? = nil
    ) {
        self.key = key
        self.name = name
        self.listRate = listRate
        self.quotaUSD = quotaUSD
        self.remainingUSD = remainingUSD
        self.endsAt = endsAt
        self.regularPromptPrice = regularPromptPrice
        self.regularCompletionPrice = regularCompletionPrice
        self.regularCacheReadPrice = regularCacheReadPrice
        self.regularCacheWritePrice = regularCacheWritePrice
    }

    /// "90% off" relative to the list price.
    public var percentOffList: Int { Int(((1 - listRate) * 100).rounded()) }

    /// True while the offer still applies: not past its end and with quota left.
    public func isLive(at now: Date) -> Bool {
        if let endsAt, endsAt <= now { return false }
        if let remainingUSD, remainingUSD <= 0 { return false }
        return true
    }
}

/// One entry of TeamoRouter's `GET /v1/user/pricing-campaigns` (`{"campaigns": [...]}`), the account's
/// claimed limited-price offers. Field names follow teamorouter.com's own dashboard code.
public struct TeamoPricingCampaign: Sendable, Hashable {
    public var key: String
    public var name: String
    public var status: String?
    /// Model ids or id prefixes ("gpt-6-astra" also covers "gpt-6-astra-2026-10-01").
    public var models: [String]
    /// Fraction of the list price charged (0.1 = 90% off).
    public var discountRate: Double
    public var quotaUSD: Double?
    public var usedUSD: Double
    public var remainingUSD: Double?
    public var claimedAt: Date?
    public var endsAt: Date?

    public init(
        key: String,
        name: String? = nil,
        status: String? = "active",
        models: [String],
        discountRate: Double,
        quotaUSD: Double? = nil,
        usedUSD: Double = 0,
        remainingUSD: Double? = nil,
        claimedAt: Date? = nil,
        endsAt: Date? = nil
    ) {
        self.key = key
        self.name = name ?? key
        self.status = status
        self.models = models
        self.discountRate = discountRate
        self.quotaUSD = quotaUSD
        self.usedUSD = usedUSD
        self.remainingUSD = remainingUSD
        self.claimedAt = claimedAt
        self.endsAt = endsAt
    }

    /// Quota left: the reported `remaining_usd`, else `quota - used`; nil when the offer has no quota cap.
    public var quotaLeftUSD: Double? {
        if let remainingUSD { return max(0, remainingUSD) }
        if let quotaUSD { return max(0, quotaUSD - usedUSD) }
        return nil
    }

    /// Claimed, still "active", not past `ends_at`, and quota left.
    public func isUsable(at now: Date) -> Bool {
        let state = status?.lowercased() ?? "active"
        guard state == "active" else { return false }
        guard discountRate > 0, discountRate < 1 else { return false }
        if let endsAt, endsAt <= now { return false }
        if let left = quotaLeftUSD, left <= 0 { return false }
        return true
    }

    public func covers(rawModelID: String) -> Bool {
        let id = rawModelID.lowercased()
        return models.contains { prefix in
            let p = prefix.lowercased()
            return !p.isEmpty && (id == p || id.hasPrefix(p + "-"))
        }
    }

    public static func parseList(_ data: Data) -> [TeamoPricingCampaign] {
        guard let root = JSONValue.parse(data) else { return [] }
        let items = root["campaigns"]?.arrayValue
            ?? root["data"]?["campaigns"]?.arrayValue
            ?? root["data"]?.arrayValue
            ?? root.arrayValue
            ?? (root["campaign"].map { [$0] } ?? [])
        return items.compactMap(parse)
    }

    static func parse(_ json: JSONValue) -> TeamoPricingCampaign? {
        func number(_ value: JSONValue?) -> Double? {
            if let d = value?.doubleValue { return d }
            if let s = value?.stringValue { return Double(s) }
            return nil
        }
        guard let rate = number(json["discount_rate"]) else { return nil }
        let models = (json["models"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard !models.isEmpty else { return nil }
        let key = json["key"]?.stringValue ?? json["id"]?.stringValue ?? "offer"
        // TeamoRouter's dashboard calls these "Surprise price"; use the campaign's own name when it sends one.
        let name = json["name"]?.stringValue ?? json["title"]?.stringValue ?? json["display_name"]?.stringValue ?? "Surprise price"
        return TeamoPricingCampaign(
            key: key,
            name: name,
            status: json["status"]?.stringValue,
            models: models,
            discountRate: rate,
            quotaUSD: number(json["quota_usd"]),
            usedUSD: number(json["used_usd"]) ?? 0,
            remainingUSD: number(json["remaining_usd"]),
            claimedAt: json["claimed_at"]?.stringValue.flatMap(ISO8601.date(from:)),
            endsAt: json["ends_at"]?.stringValue.flatMap(ISO8601.date(from:))
        )
    }
}

extension ModelInfo {
    /// Percent below the official list price that this model's current price is ("79% off list").
    public var percentOffList: Int? {
        guard let price = promptPrice, let list = listPromptPrice, list > 0, price >= 0, price < list else { return nil }
        let pct = Int(((1 - price / list) * 100).rounded())
        return pct > 0 ? pct : nil
    }

    /// This model with any offer that has ended (or run out of quota) removed, so prices go back to
    /// the regular ones without waiting for the next catalogue refresh.
    public func pricedNow(_ now: Date = Date()) -> ModelInfo {
        guard let offer = priceOffer, !offer.isLive(at: now) else { return self }
        return withoutOffer
    }

    /// Regular prices restored, offer dropped.
    public var withoutOffer: ModelInfo {
        guard let offer = priceOffer else { return self }
        var copy = self
        copy.promptPrice = offer.regularPromptPrice
        copy.completionPrice = offer.regularCompletionPrice
        copy.cacheReadPrice = offer.regularCacheReadPrice
        copy.cacheWritePrice = offer.regularCacheWritePrice
        copy.priceOffer = nil
        return copy
    }
}

extension AIProviderGateway {
    /// Reads the account's claimed pricing offers from TeamoRouter (read-only GET with the user's key).
    /// Any failure (no key, unsupported, offline) returns nil so the regular price stays in place.
    public static func fetchPricingCampaigns(
        for endpoint: AIProviderEndpoint,
        transport: any HTTPTransport
    ) async -> [TeamoPricingCampaign]? {
        guard isTeamoRouter(endpoint),
              let base = endpoint.normalizedURL,
              (try? validateEndpointURL(base)) != nil else { return nil }
        let cleanKey = AIProviderEndpoint.sanitizeAPIKey(endpoint.apiKey)
        guard !cleanKey.isEmpty else { return nil }
        let url = base.appendingPathComponent("user/pricing-campaigns")
        let headers = ["Accept": "application/json", "Authorization": "Bearer \(cleanKey)"]
        guard let resp = try? await transport.send(HTTPRequest(url: url, headers: headers, idleTimeout: 10)) else { return nil }
        // 404 means no offer for this account; other failures mean "don't know".
        if resp.status == 404 { return [] }
        guard resp.isSuccess else { return nil }
        return TeamoPricingCampaign.parseList(resp.body)
    }

    static func isTeamoRouter(_ endpoint: AIProviderEndpoint) -> Bool {
        endpoint.id == "teamorouter" || endpoint.baseURL.lowercased().contains("teamorouter")
    }

    /// Puts the account's live offers on the catalogue: a covered model's price becomes list x offer rate
    /// when that is below its regular price, with the regular price kept on `priceOffer`. Models whose
    /// offer is no longer usable go back to their regular price.
    public static func applyPricingCampaigns(
        _ models: [ModelInfo],
        campaigns: [TeamoPricingCampaign],
        now: Date = Date()
    ) -> [ModelInfo] {
        let usable = campaigns.filter { $0.isUsable(at: now) }
        return models.map { original in
            var model = original.withoutOffer
            let raw = AIProviderModelID.rawModelID(model.id)
            guard let campaign = usable.first(where: { $0.covers(rawModelID: raw) }),
                  let listIn = model.listPromptPrice, let listOut = model.listCompletionPrice else { return model }
            let rate = campaign.discountRate
            let offerIn = listIn * rate
            let offerOut = listOut * rate
            // Only ever lower the price.
            if let regIn = model.promptPrice, let regOut = model.completionPrice, offerIn + offerOut >= regIn + regOut {
                return model
            }
            let offer = PriceOffer(
                key: campaign.key,
                name: campaign.name,
                listRate: rate,
                quotaUSD: campaign.quotaUSD,
                remainingUSD: campaign.quotaLeftUSD,
                endsAt: campaign.endsAt,
                regularPromptPrice: model.promptPrice,
                regularCompletionPrice: model.completionPrice,
                regularCacheReadPrice: model.cacheReadPrice,
                regularCacheWritePrice: model.cacheWritePrice
            )
            model.promptPrice = offerIn
            model.completionPrice = offerOut
            if let listRead = model.listCacheReadPrice {
                model.cacheReadPrice = min(model.cacheReadPrice ?? .infinity, listRead * rate)
            }
            if let listWrite = model.listCacheWritePrice {
                model.cacheWritePrice = min(model.cacheWritePrice ?? .infinity, listWrite * rate)
            }
            model.priceOffer = offer
            return model
        }
    }
}
