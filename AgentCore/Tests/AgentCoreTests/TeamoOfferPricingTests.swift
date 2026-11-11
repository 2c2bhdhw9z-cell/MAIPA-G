import Foundation
import Testing
@testable import AgentCore

/// TeamoRouter's claimed "Surprise price" offer (10 November 2026): the picker and the cost figures use
/// the price the account actually pays, show the regular and list prices next to it, and go back to the
/// regular price when the offer ends or its quota is used up.
@Suite("TeamoRouter offer pricing")
struct TeamoOfferPricingTests {
    static let endpoint = AIProviderEndpoint(
        id: "teamorouter",
        name: "TeamoRouter",
        baseURL: "https://api.teamorouter.com/v1",
        apiKey: "sk-teamo-test",
        isEnabled: true
    )

    /// Trimmed copy of the public `GET /v1/models/pricing` response.
    static let pricingJSON = #"""
    {"models":[
      {"id":"gpt-6-astra","display_name":"GPT-6 Astra","context_window":1100000,"max_output_tokens":128000,
       "cost":{"input":2.14,"output":10.7,"cached_input":0.214,"cache_creation":2.675,"cache_read":0.214},
       "list_cost":{"currency":"USD","input":10.0,"output":50.0,"cached_input":1.0,"cache_creation":12.5,"cache_read":1.0},
       "discount_rate":0.214,
       "context_tier_pricing":{"threshold_tokens":272000,"input_multiplier":2.0,"output_multiplier":1.5}},
      {"id":"gpt-6.1-sol","display_name":"GPT-6.1 Sol",
       "cost":{"input":0.428,"output":2.14,"cached_input":0.0214,"cache_read":0.0214},
       "list_cost":{"currency":"USD","input":2.0,"output":10.0,"cached_input":0.1,"cache_read":0.1},
       "discount_rate":0.214,"context_tier_pricing":null},
      {"id":"gpt-6-sol","display_name":"GPT-6 Sol",
       "cost":{"input":0.44,"output":2.2},
       "list_cost":{"currency":"USD","input":2.0,"output":10.0},
       "discount_rate":0.22},
      {"id":"gpt-6.1-terra","display_name":"GPT-6.1 Terra",
       "cost":{"input":0.171,"output":0.855},
       "list_cost":{"currency":"USD","input":1.0,"output":5.0},
       "discount_rate":0.171}
    ]}
    """#

    static func campaignsJSON(status: String = "active", used: Double = 0, endsAt: String = "2099-11-29T23:59:59Z") -> String {
        #"{"campaigns":[{"key":"black_friday_2026","status":"\#(status)","models":["gpt-6-astra","gpt-6.1-sol","gpt-6-sol"],"discount_rate":0.1,"quota_usd":100,"used_usd":\#(used),"saved_usd":0,"claimed_at":"2026-11-10T12:00:00Z","ends_at":"\#(endsAt)"}]}"#
    }

    final class TeamoTransport: HTTPTransport, @unchecked Sendable {
        let campaigns: (status: Int, body: String)
        private(set) var paths: [String] = []
        private(set) var campaignAuth: String?
        init(campaigns: (status: Int, body: String)) { self.campaigns = campaigns }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            paths.append("\(request.method) \(request.url.path)")
            switch request.url.path {
            case "/v1/models":
                return HTTPResponse(status: 200, body: Data(#"{"data":[{"id":"gpt-6-astra"},{"id":"gpt-6.1-sol"},{"id":"gpt-6-sol"},{"id":"gpt-6.1-terra"}]}"#.utf8))
            case "/v1/models/pricing":
                return HTTPResponse(status: 200, body: Data(TeamoOfferPricingTests.pricingJSON.utf8))
            case "/v1/user/pricing-campaigns":
                campaignAuth = request.headers["Authorization"]
                return HTTPResponse(status: campaigns.status, body: Data(campaigns.body.utf8))
            default:
                return HTTPResponse(status: 404)
            }
        }
        func stream(_ request: HTTPRequest) async throws -> HTTPStreamResponse {
            HTTPStreamResponse(status: 404, headers: [:], body: AsyncThrowingStream { $0.finish() })
        }
    }

    static func model(_ models: [ModelInfo], _ raw: String) throws -> ModelInfo {
        try #require(models.first { AIProviderModelID.rawModelID($0.id) == raw })
    }

    static func perMillion(_ perToken: Double?) -> Double { ((perToken ?? -1) * 1_000_000 * 1_000).rounded() / 1_000 }

    @Test("The public price list gives the regular price, the list price and the long-input tier")
    func regularAndListPrices() async throws {
        let transport = TeamoTransport(campaigns: (401, #"{"error":{"type":"missing_auth_credential"}}"#))
        let models = try await AIProviderGateway.fetchModels(for: Self.endpoint, transport: transport).models
        let astra = try Self.model(models, "gpt-6-astra")
        #expect(Self.perMillion(astra.promptPrice) == 2.14)
        #expect(Self.perMillion(astra.completionPrice) == 10.7)
        #expect(Self.perMillion(astra.listPromptPrice) == 10)
        #expect(Self.perMillion(astra.listCompletionPrice) == 50)
        #expect(astra.percentOffList == 79)
        #expect(astra.priceOffer == nil)
        #expect(astra.contextTier == ContextTierPricing(thresholdTokens: 272_000, inputMultiplier: 2, outputMultiplier: 1.5))
        #expect(try Self.model(models, "gpt-6.1-sol").contextTier == nil)
    }

    @Test("A claimed offer becomes the price shown, with the regular price and quota kept")
    func claimedOfferIsThePrice() async throws {
        let transport = TeamoTransport(campaigns: (200, Self.campaignsJSON()))
        let models = try await AIProviderGateway.fetchModels(for: Self.endpoint, transport: transport).models
        // Read-only, with the user's key, and never the claim endpoint.
        #expect(transport.paths.contains("GET /v1/user/pricing-campaigns"))
        #expect(!transport.paths.contains { $0.contains("claim") })
        #expect(transport.campaignAuth == "Bearer sk-teamo-test")

        let astra = try Self.model(models, "gpt-6-astra")
        #expect(Self.perMillion(astra.promptPrice) == 1)
        #expect(Self.perMillion(astra.completionPrice) == 5)
        #expect(Self.perMillion(astra.cacheReadPrice) == 0.1)
        let offer = try #require(astra.priceOffer)
        #expect(offer.percentOffList == 90)
        #expect(offer.quotaUSD == 100)
        #expect(offer.remainingUSD == 100)
        #expect(offer.name == "Surprise price")
        #expect(Self.perMillion(offer.regularPromptPrice) == 2.14)
        #expect(Self.perMillion(offer.regularCompletionPrice) == 10.7)

        let sol61 = try Self.model(models, "gpt-6.1-sol")
        #expect(Self.perMillion(sol61.promptPrice) == 0.2)
        #expect(Self.perMillion(sol61.completionPrice) == 1)
        let sol = try Self.model(models, "gpt-6-sol")
        #expect(Self.perMillion(sol.promptPrice) == 0.2)
        #expect(Self.perMillion(sol.completionPrice) == 1)

        // Not in the offer: regular price.
        let terra = try Self.model(models, "gpt-6.1-terra")
        #expect(terra.priceOffer == nil)
        #expect(Self.perMillion(terra.promptPrice) == 0.171)
        #expect(Self.perMillion(terra.completionPrice) == 0.855)
    }

    @Test("Used-up quota, an ended offer or a past end date leave the regular price")
    func offerOverMeansRegularPrice() async throws {
        for body in [
            Self.campaignsJSON(used: 100),
            Self.campaignsJSON(status: "exhausted", used: 100),
            Self.campaignsJSON(status: "ended"),
            Self.campaignsJSON(endsAt: "2026-11-01T00:00:00Z"),
        ] {
            let models = try await AIProviderGateway.fetchModels(for: Self.endpoint, transport: TeamoTransport(campaigns: (200, body))).models
            let astra = try Self.model(models, "gpt-6-astra")
            #expect(astra.priceOffer == nil)
            #expect(Self.perMillion(astra.promptPrice) == 2.14)
        }
        // The campaign endpoint failing never breaks the list.
        let failed = try await AIProviderGateway.fetchModels(for: Self.endpoint, transport: TeamoTransport(campaigns: (500, "oops"))).models
        #expect(Self.perMillion(try Self.model(failed, "gpt-6-astra").promptPrice) == 2.14)
    }

    @Test("Re-applying fresh offer data reverts a model whose offer just ran out")
    func reapplyReverts() throws {
        let now = try #require(ISO8601.date(from: "2026-11-11T00:00:00Z"))
        let base = ModelInfo(
            id: AIProviderModelID.encode(providerID: "teamorouter", rawModelID: "gpt-6-astra"),
            name: "TeamoRouter: GPT-6 Astra",
            promptPrice: 2.14e-6,
            completionPrice: 10.7e-6,
            listPromptPrice: 10e-6,
            listCompletionPrice: 50e-6
        )
        let live = TeamoPricingCampaign(key: "bf", models: ["gpt-6-astra"], discountRate: 0.1, quotaUSD: 100, usedUSD: 40)
        let discounted = AIProviderGateway.applyPricingCampaigns([base], campaigns: [live], now: now)[0]
        #expect(Self.perMillion(discounted.promptPrice) == 1)
        #expect(discounted.priceOffer?.remainingUSD == 60)

        var spent = live
        spent.usedUSD = 100
        let reverted = AIProviderGateway.applyPricingCampaigns([discounted], campaigns: [spent], now: now)[0]
        #expect(reverted == base)
        // No offers at all also reverts.
        #expect(AIProviderGateway.applyPricingCampaigns([discounted], campaigns: [], now: now)[0] == base)
    }

    @Test("Campaign model prefixes cover dated variants only")
    func campaignCoverage() {
        let c = TeamoPricingCampaign(key: "bf", models: ["gpt-6-sol"], discountRate: 0.1)
        #expect(c.covers(rawModelID: "gpt-6-sol"))
        #expect(c.covers(rawModelID: "GPT-6-Sol-2026-10-01"))
        #expect(!c.covers(rawModelID: "gpt-6-solar"))
        #expect(!c.covers(rawModelID: "gpt-6.1-sol"))
    }

    @Test("Cost estimates use the offer price, the regular price after it ends, and the long-input tier")
    func costUsesEffectivePrice() throws {
        let offerModel = ModelInfo(
            id: AIProviderModelID.encode(providerID: "teamorouter", rawModelID: "gpt-6-astra"),
            name: "TeamoRouter: GPT-6 Astra",
            promptPrice: 1e-6,
            completionPrice: 5e-6,
            listPromptPrice: 10e-6,
            listCompletionPrice: 50e-6,
            contextTier: ContextTierPricing(thresholdTokens: 272_000, inputMultiplier: 2, outputMultiplier: 1.5),
            priceOffer: PriceOffer(key: "bf", name: "Surprise price", listRate: 0.1, quotaUSD: 100, remainingUSD: 100,
                                   endsAt: Date().addingTimeInterval(86_400), regularPromptPrice: 2.14e-6, regularCompletionPrice: 10.7e-6)
        )
        let usage = Usage(promptTokens: 1_000_000, completionTokens: 100_000)
        // Over the 272K tier: (1M x $1 x 2) + (100K x $5 x 1.5) = $2 + $0.75
        let discounted = AIProviderGateway.withFallbackCost(usage, rawModelID: "gpt-6-astra", endpoint: Self.endpoint, catalogueModel: offerModel)
        #expect(abs((discounted.cost ?? 0) - 2.75) < 0.000_001)
        #expect(discounted.costIsEstimate == true)

        let small = Usage(promptTokens: 100_000, completionTokens: 10_000)
        let smallCost = AIProviderGateway.withFallbackCost(small, rawModelID: "gpt-6-astra", endpoint: Self.endpoint, catalogueModel: offerModel)
        #expect(abs((smallCost.cost ?? 0) - 0.15) < 0.000_001)

        var ended = offerModel
        ended.priceOffer?.endsAt = Date().addingTimeInterval(-60)
        let regular = AIProviderGateway.withFallbackCost(small, rawModelID: "gpt-6-astra", endpoint: Self.endpoint, catalogueModel: ended)
        #expect(abs((regular.cost ?? 0) - (0.214 + 0.107)) < 0.000_001)

        // What TeamoRouter itself reports always wins.
        let reported = AIProviderGateway.withFallbackCost(Usage(promptTokens: 100_000, completionTokens: 10_000, cost: 0.123), rawModelID: "gpt-6-astra", endpoint: Self.endpoint, catalogueModel: offerModel)
        #expect(reported.cost == 0.123)
        #expect(reported.costIsEstimate == nil)
    }

    @Test("Saved catalogues without the new price fields still load")
    func oldCacheDecodes() throws {
        let json = #"[{"id":"teamorouter::gpt-6-astra","name":"TeamoRouter: GPT-6 Astra","promptPrice":2.14e-6,"completionPrice":1.07e-5,"inputModalities":["text"],"outputModalities":["text"],"supportedParameters":[]}]"#
        let decoded = try JSONDecoder().decode([ModelInfo].self, from: Data(json.utf8))
        #expect(decoded.first?.priceOffer == nil)
        #expect(decoded.first?.listPromptPrice == nil)
        let roundTrip = try JSONDecoder().decode([ModelInfo].self, from: JSONEncoder().encode(decoded))
        #expect(roundTrip == decoded)
    }
}
