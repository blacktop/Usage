/// Every boundary a provider is allowed to touch, injected explicitly.
///
/// A provider reads no global process state: no `URLSession.shared`, no `FileManager.default`, no
/// `Date()`, no ambient Keychain policy. That is what makes the whole provider layer testable with
/// in-memory doubles and what keeps a background refresh from raising UI.
public struct ProviderContext: Sendable {
    public let http: any HTTPTransport
    public let credentials: any CredentialSource
    public let fileSystem: any ProviderFileSystem
    public let clock: any UsageClock
    public let interaction: any InteractionPolicy

    public init(
        http: any HTTPTransport,
        credentials: any CredentialSource,
        fileSystem: any ProviderFileSystem,
        clock: any UsageClock,
        interaction: any InteractionPolicy
    ) {
        self.http = http
        self.credentials = credentials
        self.fileSystem = fileSystem
        self.clock = clock
        self.interaction = interaction
    }

    /// The context the app's scheduled refreshes and the whole CLI run under.
    ///
    /// `BackgroundInteractionPolicy` by default, including for the CLI: a command run from a
    /// terminal is still not a place to raise a Keychain dialog. Only an explicit Settings action
    /// passes a policy that allows one.
    public static func system(
        interaction: any InteractionPolicy = BackgroundInteractionPolicy()
    ) -> ProviderContext {
        let fileSystem = SystemFileSystem()
        return ProviderContext(
            http: URLSessionTransport(),
            credentials: SystemCredentialSource(fileSystem: fileSystem, interaction: interaction),
            fileSystem: fileSystem,
            clock: SystemClock(),
            interaction: interaction
        )
    }
}
