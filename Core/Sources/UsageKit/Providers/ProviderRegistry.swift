/// The complete list of provider implementations. Registration is this array and nothing else.
///
/// Lookup returns an optional rather than trapping: an unknown identifier comes from persisted
/// state or a CLI flag, and neither is a programmer error.
public struct ProviderRegistry: Sendable {
    public let providers: [any Provider]

    public init(providers: [any Provider]) {
        self.providers = providers
    }

    public func provider(for id: ProviderID) -> (any Provider)? {
        providers.first { $0.providerID == id }
    }

    public var providerIDs: [ProviderID] {
        providers.map(\.providerID)
    }

    /// Requested identifiers resolved against registration, de-duplicated, in the order given.
    ///
    /// An empty request means every registered provider. Unknown names are reported together
    /// rather than one at a time, so a mistyped command is corrected in one round trip.
    public func resolve(_ requested: [String]) throws(UnknownProviderIDs) -> [ProviderID] {
        guard !requested.isEmpty else { return providerIDs }
        var resolved: [ProviderID] = []
        var unknown: [String] = []
        for name in requested {
            let id = ProviderID(name.lowercased())
            if provider(for: id) == nil {
                unknown.append(name)
            } else if !resolved.contains(id) {
                resolved.append(id)
            }
        }
        guard unknown.isEmpty else { throw UnknownProviderIDs(names: unknown) }
        return resolved
    }

    /// Every provider implementation that exists. Adding a provider is this line and nothing else.
    ///
    /// Whether a provider reports anything is decided by configuration, not by registration: a
    /// registered provider with no enabled root discovers nothing.
    public static let agents = ProviderRegistry(
        providers: [CodexProvider(), ClaudeProvider(), CopilotProvider()]
    )

    /// The providers a shipped host runs.
    ///
    /// The same list as `agents`, and named separately only because the CLI reads it under that
    /// name. There is nothing left to gate on: every account comes from a root the user configured
    /// and every credential from a file below it, so no provider needs a per-host capability the
    /// app has and the CLI does not.
    public static let commandLine = agents
}

/// Requested identifiers that name no registered provider.
public struct UnknownProviderIDs: Error, Sendable, Hashable {
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }
}
