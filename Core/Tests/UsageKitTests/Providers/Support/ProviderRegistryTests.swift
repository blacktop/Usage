import Foundation
import Testing

@testable import UsageKit

@Suite("Provider registry")
struct ProviderRegistryTests {
    @Test("every agent provider is registered exactly once")
    func registersEveryAgent() {
        let ids = ProviderRegistry.agents.providerIDs
        #expect(ids == [CodexProvider.id, ClaudeProvider.id, CopilotProvider.id])
        #expect(Set(ids).count == ids.count)
    }

    @Test("each registered provider is reachable by its identifier")
    func looksUpByIdentifier() throws {
        for id in ProviderRegistry.agents.providerIDs {
            #expect(ProviderRegistry.agents.provider(for: id)?.providerID == id)
        }
        #expect(ProviderRegistry.agents.provider(for: ProviderID("nope")) == nil)
    }

    @Test("every literal endpoint and dashboard URL parses as https")
    func literalURLsAreWellFormed() throws {
        let urls =
            [
                CodexProvider.usageURL,
                ClaudeProvider.usageURL,
                try #require(CopilotProvider.usageURL(host: "github.com")),
            ] + ProviderRegistry.agents.providers.map(\.dashboardURL)

        for url in urls {
            #expect(url.scheme == "https", "\(url) is not an https URL")
            #expect(url.host() != nil)
        }
    }

    @Test("providers default to one fetch at a time")
    func defaultsToSequentialFetches() {
        #expect(ProviderRegistry.agents.providers.allSatisfy { $0.maxConcurrentFetches == 1 })
    }
}
