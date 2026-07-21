import Foundation

/// One agent's usage source. The entire provider surface is these five members.
public protocol Provider: Sendable {
    static var id: ProviderID { get }
    /// Instance-side spelling of `Self.id`. A requirement rather than only an extension member, so
    /// that looking a provider up by identity through `any Provider` dispatches dynamically.
    var providerID: ProviderID { get }
    var displayName: String { get }
    var dashboardURL: URL { get }
    /// Upper bound on this provider's simultaneous fetches. Conservative by default because
    /// undocumented endpoints punish bursts.
    var maxConcurrentFetches: Int { get }

    /// Enumerates locally available accounts. Must never trigger credential UI.
    func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount]

    func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport
}

extension Provider {
    public var maxConcurrentFetches: Int { 1 }

    public var providerID: ProviderID { Self.id }
}
