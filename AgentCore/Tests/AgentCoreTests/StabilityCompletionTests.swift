import Foundation
import Testing
@testable import AgentCore

@Suite("Stability list completion")
struct StabilityCompletionTests {
    // Stability 14: GitHub's current usage report replaces the retired billing/actions endpoint.
    @Test func S14_actionsMinutesComeFromTheUsageReport() throws {
        let json = Data("""
        {"usageItems":[
          {"date":"2026-10-02","product":"Actions","sku":"Actions Linux","quantity":100,"unitType":"minutes","pricePerUnit":0.008,"grossAmount":0.8,"discountAmount":0.8,"netAmount":0,"repositoryName":"me/private-app"},
          {"date":"2026-10-03","product":"Actions","sku":"Actions macOS 3-core","quantity":12,"unitType":"Minutes","pricePerUnit":0.08,"grossAmount":0.96,"discountAmount":0.96,"netAmount":0,"repositoryName":"me/private-app"},
          {"date":"2026-10-03","product":"Actions","sku":"Actions Windows","quantity":5,"unitType":"minutes","netAmount":0,"repositoryName":"me/private-app"},
          {"date":"2026-10-04","product":"Actions","sku":"Actions Linux","quantity":900,"unitType":"minutes","netAmount":0,"repositoryName":"me/Public-Site"},
          {"date":"2026-10-04","product":"Actions","sku":"Actions storage","quantity":3,"unitType":"GigabyteHours","netAmount":0,"repositoryName":"me/private-app"},
          {"date":"2026-10-04","product":"Copilot","sku":"Copilot Premium Request","quantity":40,"unitType":"requests","netAmount":0}
        ]}
        """.utf8)
        let report = try JSONCoding.decoder().decode(GitHubUsageReport.self, from: json)
        let billing = GitHubActionsBilling.summarize(report.usageItems, publicRepos: ["me/public-site"], plan: "free")
        // 100 Linux + 12 × 10 macOS + 5 × 2 Windows; the public repo and non-minute rows don't count.
        #expect(billing.totalMinutesUsed == 230)
        #expect(billing.includedMinutes == 2_000)
        #expect(billing.includedMinutesRemaining == 1_770)
        #expect(!billing.isLow)
        #expect(GitHubActionsBilling.summarize(report.usageItems, publicRepos: [], plan: "pro").includedMinutes == 3_000)

        let overage = GitHubActionsBilling.summarize([
            GitHubUsageItem(product: "Actions", sku: "Actions Linux", quantity: 2_100, unitType: "minutes", netAmount: 0.8, repositoryName: "me/private-app"),
        ], publicRepos: [], plan: nil)
        #expect(overage.includedMinutesRemaining == 0 && overage.isLow && overage.paidAmount == 0.8)

        let forbidden = GitHubActionsBilling.explain(HTTPError.status(code: 403, body: "Resource not accessible by integration", headers: [:]))
        #expect(forbidden.contains("Plan") && forbidden.contains("Read-only"))
    }
}
