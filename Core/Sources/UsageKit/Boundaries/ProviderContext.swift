/// Every boundary a provider is allowed to touch, injected explicitly.
///
/// A provider reads no global process state: no `URLSession.shared`, no `FileManager.default`, no
/// `Date()`, no ambient Keychain policy, and no home-directory guess about where an agent keeps its
/// configuration. That is what makes the whole provider layer testable with in-memory doubles and
/// what keeps a background refresh from raising UI.
public struct ProviderContext: Sendable {
    public let http: any HTTPTransport
    public let credentials: any CredentialSource
    public let fileSystem: any ProviderFileSystem
    public let clock: any UsageClock
    public let interaction: any InteractionPolicy
    /// The configured configuration roots, which are the only source account discovery has.
    public let profileRoots: any ProfileRootStore
    /// The Usage-owned store a provider may mirror a last-good credential into, or `nil` where
    /// mirroring is not configured.
    ///
    /// `nil` for the CLI on purpose: the app and the CLI are two code identities, and an item
    /// either one created is approval-gated for the other — a CLI-written mirror would be a row
    /// the app can never read silently.
    public let managedCredentials: (any ManagedCredentialStore)?

    /// Builds a context, defaulting the root store to the seeded roots under the injected home.
    ///
    /// The default exists so a fixture context discovers exactly the roots its own fake file system
    /// was seeded with: an in-memory store reads no preferences domain, so a test can neither see
    /// nor disturb the roots the running user configured. A host that means to read real
    /// configuration passes `UserDefaultsProfileRootStore`, which `system()` does.
    public init(
        http: any HTTPTransport,
        credentials: any CredentialSource,
        fileSystem: any ProviderFileSystem,
        clock: any UsageClock,
        interaction: any InteractionPolicy,
        profileRoots: (any ProfileRootStore)? = nil,
        managedCredentials: (any ManagedCredentialStore)? = nil
    ) {
        self.http = http
        self.credentials = credentials
        self.fileSystem = fileSystem
        self.clock = clock
        self.interaction = interaction
        self.profileRoots =
            profileRoots ?? InMemoryProfileRootStore(homeDirectory: fileSystem.homeDirectory)
        self.managedCredentials = managedCredentials
    }

    /// The context the app's scheduled refreshes and the whole CLI run under.
    ///
    /// `BackgroundInteractionPolicy` by default, including for the CLI: a command run from a
    /// terminal is still not a place to raise a Keychain dialog. Only an explicit account approval
    /// action passes a policy that allows one.
    public static func system(
        interaction: any InteractionPolicy = BackgroundInteractionPolicy(),
        managedCredentials: (any ManagedCredentialStore)? = nil
    ) -> ProviderContext {
        let fileSystem = SystemFileSystem()
        return ProviderContext(
            http: URLSessionTransport(),
            credentials: SystemCredentialSource(fileSystem: fileSystem, interaction: interaction),
            fileSystem: fileSystem,
            clock: SystemClock(),
            interaction: interaction,
            profileRoots: UserDefaultsProfileRootStore(homeDirectory: fileSystem.homeDirectory),
            managedCredentials: managedCredentials
        )
    }
}
