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
    /// Implemented is not the same as enabled: this list is what the contract tests enumerate, not
    /// what a host runs.
    public static let agents = ProviderRegistry(
        providers: [CodexProvider(), ClaudeProvider(), CopilotProvider()]
    )

    /// The providers the shipped CLI runs.
    ///
    /// Claude and Copilot are Phase 5 work, and Claude additionally waits on the Keychain
    /// feasibility gate — an explicit user approval this build does not have. Keychain access is a
    /// per-host capability, so the CLI's registry is separate from the app's rather than shared.
    /// Until the gate is recorded an unapproved provider is absent here, which means `usage` reads
    /// neither `Claude Code-credentials` nor `~/.config/github-copilot` and contacts neither
    /// endpoint, rather than being present and failing at the credential.
    public static let commandLine = ProviderRegistry(providers: [CodexProvider()])
}

/// Requested identifiers that name no registered provider.
public struct UnknownProviderIDs: Error, Sendable, Hashable {
    public let names: [String]

    public init(names: [String]) {
        self.names = names
    }
}
