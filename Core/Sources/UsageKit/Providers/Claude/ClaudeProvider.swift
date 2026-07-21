import Foundation

/// Claude / Claude Code, read through Claude Code's own credential storage.
///
/// Read-only: Usage never refreshes the OAuth token, never writes the Keychain item, and never
/// launches the `claude` binary to make it refresh on our behalf. An expired credential surfaces
/// `.authenticationExpired`, and the user runs `claude login` themselves.
///
/// Enumeration is attributes-only and must never issue a query that can raise credential UI, which
/// is why the plan label is only known for a file-backed credential: reading a Keychain item's data
/// to recover `subscriptionType` would mean a data-returning query during a background refresh.
public struct ClaudeProvider: Provider {
    public static let id = ProviderID("claude")

    static let usageURL = StaticURL.make("https://api.anthropic.com/api/oauth/usage")
    static let betaHeader = "oauth-2025-04-20"
    /// Sent instead of `Usage/<version>` because this endpoint is Claude Code's own and the header
    /// may be load-bearing. Divergence from every other provider is deliberate.
    static let userAgent = "claude-code/2.1.0"
    static let keychainSlotSource = "claude.keychain"
    static let fileSlotSource = "claude.credentials-file"

    public let displayName = "Claude"
    public let dashboardURL = StaticURL.make("https://claude.ai/settings/usage")

    public init() {}

    static var keychainNamespace: CredentialLocator {
        CredentialLocator(kind: .keychain, identifier: ClaudeCredentialFile.keychainService)
    }

    /// Enumerates Keychain slots first, falling back to the credential file.
    ///
    /// The two are the same credential in different homes, not two accounts, so the file is only
    /// consulted when the Keychain has nothing to offer. Several Keychain items under one service
    /// genuinely are several accounts, and each becomes its own slot; the newest is the one Claude
    /// Code is currently signed in as.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        let slots = (try? await context.credentials.slots(in: Self.keychainNamespace)) ?? []
        if !slots.isEmpty {
            return slots.enumerated().map { index, descriptor in
                Self.account(from: descriptor, availability: index == 0 ? .active : .inactive)
            }
        }
        return Self.fileAccounts(using: context)
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        let metadata = Self.fileMetadata(for: account, using: context)
        if let metadata, metadata.isExpired(at: context.clock.now) {
            throw UsageError(
                category: .authenticationExpired,
                reason: .credentialUnavailable(kind: account.locator.kind)
            )
        }
        let response = try await context.credentials.withCredential(at: account.locator) {
            credential in
            try await context.http.send(credential.authorizing(Self.usageRequest(), with: .bearer))
        }
        guard response.isSuccess else {
            throw UsageError.from(response, now: context.clock.now)
        }
        return try ClaudeUsageMapper.report(
            from: ClaudeUsageResponse.decode(response.body),
            account: account,
            plan: metadata?.planLabel,
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

    private static func account(
        from descriptor: CredentialSlotDescriptor,
        availability: ProviderAccount.Availability
    ) -> ProviderAccount {
        ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .credentialSlot(provider: id, slot: descriptor.slot)
            ),
            slot: descriptor.slot,
            locator: CredentialLocator(
                kind: descriptor.locator.kind,
                identifier: descriptor.locator.identifier,
                path: ClaudeCredentialFile.secretPath
            ),
            displayName: descriptor.displayName,
            availability: availability
        )
    }

    private static func fileAccounts(using context: ProviderContext) -> [ProviderAccount] {
        let url = ClaudeCredentialFile.url(home: context.fileSystem.homeDirectory)
        guard context.fileSystem.fileExists(at: url),
            let data = try? context.fileSystem.read(contentsOf: url)
        else { return [] }
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let slot = CredentialSlotID(source: fileSlotSource, opaqueID: path)
        let metadata = try? ClaudeCredentialFile.parse(data, kind: .file)
        let expired = metadata?.isExpired(at: context.clock.now) ?? true
        return [
            ProviderAccount(
                key: AccountKey(
                    providerID: id,
                    accountID: .credentialSlot(provider: id, slot: slot)
                ),
                slot: slot,
                locator: CredentialLocator(
                    kind: .file,
                    identifier: path,
                    path: ClaudeCredentialFile.secretPath
                ),
                displayName: metadata?.planLabel,
                availability: expired ? .unavailable : .active
            )
        ]
    }

    /// Metadata for a file-backed account, which is where the plan label and the local expiry check
    /// come from. Keychain-backed accounts have neither, by design.
    private static func fileMetadata(
        for account: ProviderAccount,
        using context: ProviderContext
    ) -> ClaudeCredentialMetadata? {
        guard account.locator.kind == .file else { return nil }
        let url = URL(filePath: account.locator.identifier)
        guard let data = try? context.fileSystem.read(contentsOf: url) else { return nil }
        return try? ClaudeCredentialFile.parse(data, kind: .file)
    }
}
