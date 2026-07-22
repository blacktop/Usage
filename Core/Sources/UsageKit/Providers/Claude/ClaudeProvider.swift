import Foundation

/// Claude / Claude Code, read through each configured root's credential file or Keychain item.
///
/// Read-only: Usage never refreshes the OAuth token, never writes the credential file, and never
/// launches the `claude` binary to make it refresh on our behalf. The provider is authoritative
/// about expiry: Claude Code continues presenting credentials whose local timestamp has passed,
/// so Usage does the same and treats an HTTP 401 or 403 as the authentication decision.
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
    /// Claude Code uses an unsuffixed Keychain service for its default `~/.claude` root and hashes
    /// an explicit `CLAUDE_CONFIG_DIR` into a root-scoped service. Enumeration reads attributes and
    /// a persistent row reference only; payload access remains subject to the interaction policy.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        for root in try await context.enabledProfileRoots(for: Self.id) {
            if let account = Self.fileAccount(in: root, using: context) {
                accounts.append(account)
                continue
            }
            for service in Self.keychainServices(
                root: root.directory,
                homeDirectory: context.fileSystem.homeDirectory
            ) {
                let namespace = CredentialLocator(kind: .keychain, identifier: service)
                guard
                    let descriptors = try? await context.credentials.slots(in: namespace),
                    let descriptor = Self.currentDescriptor(
                        in: descriptors,
                        homeDirectory: context.fileSystem.homeDirectory
                    )
                else { continue }
                accounts.append(Self.keychainAccount(descriptor: descriptor, root: root))
                break
            }
        }
        return accounts
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        let result = try await context.credentials.withCredential(at: account.locator) {
            credential in
            let metadata =
                try credential.metadata {
                    (data: Data) throws(UsageError) -> ClaudeCredentialMetadata in
                    try ClaudeCredentialFile.parse(data, kind: account.locator.kind)
                } ?? Self.fileMetadata(for: account, using: context)
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
        let hasUsableCredential = (try? ClaudeCredentialFile.parse(data, kind: .file)) != nil
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
            availability: hasUsableCredential ? .active : .unavailable
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

    /// The default profile is special: Claude Code omits the config-directory hash unless
    /// `CLAUDE_CONFIG_DIR` was explicitly supplied. Keep the hashed name as a compatibility
    /// fallback for installations that previously launched the default path explicitly.
    private static func keychainServices(root: URL, homeDirectory: URL) -> [String] {
        let scoped = ClaudeCredentialFile.keychainService(root: root)
        guard ClaudeCredentialFile.isDefaultRoot(root, homeDirectory: homeDirectory) else {
            return [scoped]
        }
        return [ClaudeCredentialFile.keychainService, scoped]
    }

    /// Claude Code filters Keychain rows by the current macOS account. The injected home gives us
    /// the same non-secret selector without consulting process globals. Do not borrow another
    /// user's sole visible row: an account-label mismatch fails closed just as Claude Code does.
    private static func currentDescriptor(
        in descriptors: [CredentialSlotDescriptor],
        homeDirectory: URL
    ) -> CredentialSlotDescriptor? {
        let userName = homeDirectory.standardizedFileURL.lastPathComponent
        return descriptors.first { $0.displayName == userName }
    }

    /// Metadata for the account's credential document, which is where the plan label comes from.
    ///
    /// Only reached when the credential source handed back no document — the production file source
    /// always does, so this costs nothing on the shipped path. Read fresh rather than cached at
    /// discovery because Claude Code can rewrite the document between discovery and fetch.
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
