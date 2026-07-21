import Foundation

/// Claude / Claude Code, read through the `.credentials.json` below each configured root.
///
/// Read-only: Usage never refreshes the OAuth token, never writes the credential file, and never
/// launches the `claude` binary to make it refresh on our behalf. An expired credential surfaces
/// `.authenticationExpired`, and the user runs `claude login` themselves.
public struct ClaudeProvider: Provider {
    public static let id = ProviderID("claude")

    static let usageURL = StaticURL.make("https://api.anthropic.com/api/oauth/usage")
    static let betaHeader = "oauth-2025-04-20"
    /// Sent instead of `Usage/<version>` because this endpoint is Claude Code's own and the header
    /// may be load-bearing. Divergence from every other provider is deliberate.
    static let userAgent = "claude-code/2.1.0"
    static let slotSource = "claude.credentials-file"

    public let displayName = "Claude"
    public let dashboardURL = StaticURL.make("https://claude.ai/settings/usage")

    public init() {}

    /// One account per enabled configured root with file- or Keychain-backed CLI authentication.
    ///
    /// Current Claude Code hashes `CLAUDE_CONFIG_DIR` into the Keychain service name, so the item
    /// is root-scoped and distinct across profiles. Enumeration reads attributes and a persistent
    /// row reference only; payload access remains subject to the context's interaction policy.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        for root in try await context.enabledProfileRoots(for: Self.id) {
            if let account = Self.fileAccount(in: root, using: context) {
                accounts.append(account)
                continue
            }
            let service = ClaudeCredentialFile.keychainService(root: root.directory)
            let namespace = CredentialLocator(kind: .keychain, identifier: service)
            guard let descriptor = try? await context.credentials.slots(in: namespace).first else {
                continue
            }
            accounts.append(Self.keychainAccount(descriptor: descriptor, root: root))
        }
        return accounts
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        let fallbackMetadata = Self.fileMetadata(for: account, using: context)
        let result = try await context.credentials.withCredential(at: account.locator) {
            credential in
            let metadata =
                try credential.metadata {
                    (data: Data) throws(UsageError) -> ClaudeCredentialMetadata in
                    try ClaudeCredentialFile.parse(data, kind: account.locator.kind)
                } ?? fallbackMetadata
            if let metadata, metadata.isExpired(at: context.clock.now) {
                throw UsageError(
                    category: .authenticationExpired,
                    reason: .credentialUnavailable(kind: account.locator.kind)
                )
            }
            let response = try await context.http.send(
                credential.authorizing(Self.usageRequest(), with: .bearer)
            )
            return CredentialOperationResponse(response: response, metadata: metadata)
        }
        guard result.response.isSuccess else {
            throw UsageError.from(result.response, now: context.clock.now)
        }
        return try ClaudeUsageMapper.report(
            from: ClaudeUsageResponse.decode(result.response.body),
            account: account,
            plan: result.metadata?.planLabel,
            capturedAt: context.clock.now
        )
    }

    /// The usage request, minus authorization.
    ///
    /// `anthropic-beta` is required. There is deliberately no `anthropic-version`: that header
    /// belongs to the Admin API, not to this route.
    static func usageRequest() -> HTTPRequest {
        HTTPRequest(
            method: .get,
            url: usageURL,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": betaHeader,
                "User-Agent": userAgent,
            ]
        )
    }

    /// The account one root describes, or nothing at all when the root holds no credential
    /// document.
    ///
    /// Identity is the file's own path, so two roots are two accounts even when the same person is
    /// signed in under both — which is the point of configuring them separately.
    private static func fileAccount(
        in root: ProfileRootLocation,
        using context: ProviderContext
    ) -> ProviderAccount? {
        let url = ClaudeCredentialFile.url(root: root.directory)
        guard context.fileSystem.fileExists(at: url),
            let data = try? context.fileSystem.read(contentsOf: url)
        else { return nil }
        let slot = Self.slot(for: root.directory)
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let metadata = try? ClaudeCredentialFile.parse(data, kind: .file)
        let expired = metadata?.isExpired(at: context.clock.now) ?? true
        return ProviderAccount(
            key: AccountKey(providerID: id, accountID: .credentialSlot(provider: id, slot: slot)),
            slot: slot,
            locator: CredentialLocator(
                kind: .file,
                identifier: path,
                path: ClaudeCredentialFile.secretPath
            ),
            profileRootID: root.id,
            displayName: root.label,
            availability: expired ? .unavailable : .active
        )
    }

    private static func keychainAccount(
        descriptor: CredentialSlotDescriptor,
        root: ProfileRootLocation
    ) -> ProviderAccount {
        let slot = Self.slot(for: root.directory)
        let locator = CredentialLocator(
            kind: .keychain,
            identifier: descriptor.locator.identifier,
            path: ClaudeCredentialFile.secretPath
        )
        return ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .credentialSlot(provider: id, slot: slot)
            ),
            slot: slot,
            locator: locator,
            profileRootID: root.id,
            displayName: root.label,
            availability: .active
        )
    }

    /// Metadata for the account's credential document, which is where the plan label and the local
    /// expiry check come from.
    ///
    /// Read fresh on every fetch rather than cached at discovery, because Claude Code rewrites the
    /// document whenever it refreshes and a cached expiry would reject a credential that has since
    /// been renewed.
    private static func fileMetadata(
        for account: ProviderAccount,
        using context: ProviderContext
    ) -> ClaudeCredentialMetadata? {
        guard account.locator.kind == .file else { return nil }
        let url = URL(filePath: account.locator.identifier)
        guard let data = try? context.fileSystem.read(contentsOf: url) else { return nil }
        return try? ClaudeCredentialFile.parse(data, kind: .file)
    }

    /// Stable logical slot for a configured root, independent of its current credential store.
    private static func slot(for root: URL) -> CredentialSlotID {
        let path = ClaudeCredentialFile.url(root: root)
            .standardizedFileURL.path(percentEncoded: false)
        return CredentialSlotID(source: slotSource, opaqueID: path)
    }
}
