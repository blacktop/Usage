import Foundation

/// Claude / Claude Code, read through each configured root's credential file, Claude Code's own
/// root-scoped Keychain item, or a Usage setup token — in that order.
///
/// Read-only: Usage never refreshes the OAuth token, never writes the credential file, and never
/// writes, updates, or deletes Claude Code's Keychain item. The Keychain tier addresses only the
/// default root's plain service or a custom root's hashed service (`ClaudeCodeKeychain`), confirmed
/// by the Gate A diagnostic. A setup token is written only by an explicit Settings action into a
/// Usage-owned item and is resolved through the same operation-scoped boundary as every other
/// credential.
public struct ClaudeProvider: Provider {
    public static let id = ProviderID("claude")

    static let usageURL = StaticURL.make("https://api.anthropic.com/api/oauth/usage")
    static let messagesURL = StaticURL.make("https://api.anthropic.com/v1/messages")
    static let betaHeader = "oauth-2025-04-20"
    /// Sent instead of `Usage/<version>` because this endpoint is Claude Code's own and the header
    /// may be load-bearing. Divergence from every other provider is deliberate.
    static let userAgent = "claude-code/2.1.0"
    static let slotSource = "claude.credentials-file"

    public let displayName = "Claude"
    public let dashboardURL = StaticURL.make("https://claude.ai/settings/usage")

    public init() {}

    /// One account per enabled configured root, resolved file → Claude Code Keychain → setup
    /// token.
    ///
    /// A usable credential file wins outright. When it is absent or unusable, discovery consults
    /// Claude Code's own Keychain service (attributes only, newest row first) and then Usage's own
    /// service for a token explicitly saved against this root. The plain service is queried only
    /// for the exact injected `HOME/.claude` root; custom roots use their path-hashed service.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        let roots = try await context.enabledProfileRoots(for: Self.id)
        guard !roots.isEmpty else { return [] }
        let setupTokens =
            (try? await context.credentials.slots(in: ClaudeSetupTokenCredential.namespace)) ?? []
        let setupTokenByAccount = Dictionary(
            setupTokens.compactMap { descriptor -> (String, CredentialSlotDescriptor)? in
                guard descriptor.locator.kind == .appKeychain,
                    descriptor.locator.identifier == ClaudeSetupTokenCredential.service,
                    descriptor.locator.path.count == 1,
                    let account = descriptor.locator.path.first
                else { return nil }
                return (account, descriptor)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var accounts: [ProviderAccount] = []
        for root in roots {
            let fileAccount = Self.fileAccount(in: root, using: context)
            if let fileAccount, fileAccount.availability == .active {
                accounts.append(fileAccount)
                continue
            }
            if let keychainAccount = await Self.claudeCodeKeychainAccount(
                in: root, using: context)
            {
                accounts.append(keychainAccount)
                continue
            }
            if let descriptor = setupTokenByAccount[root.id.description] {
                accounts.append(Self.setupTokenAccount(descriptor: descriptor, root: root))
                continue
            }
            if let fileAccount {
                accounts.append(fileAccount)
            }
        }
        return accounts
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        do {
            return try await fetch(for: account, using: context)
        } catch {
            throw Self.annotated(error, for: account.locator)
        }
    }

    private func fetch(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        if account.locator.kind == .appKeychain {
            return try await fetchSetupTokenUsage(for: account, using: context)
        }
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

    /// One minimal inference request whose response carries unified subscription-window headers.
    ///
    /// `claude setup-token` is intentionally inference-only and receives HTTP 403 from
    /// `/api/oauth/usage`, which requires `user:profile`. The Messages API accepts that token and
    /// returns the 5-hour and 7-day utilization/reset values on the response. This request consumes
    /// a tiny amount of the account's allowance; it is never made during discovery.
    static func setupTokenProbeRequest() -> HTTPRequest {
        HTTPRequest(
            method: .post,
            url: messagesURL,
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
                "anthropic-beta": betaHeader,
                "anthropic-version": "2023-06-01",
                "User-Agent": userAgent,
            ],
            body: Data(
                """
                {
                  "model": "claude-haiku-4-5-20251001",
                  "max_tokens": 1,
                  "messages": [{"role": "user", "content": "."}]
                }
                """.utf8
            )
        )
    }

    /// The recovery instruction for one credential backend, or `nil` where none is truthful.
    ///
    /// Only the backend decides the honest instruction: running `claude` refreshes the CLI's own
    /// Keychain item, but it neither writes `.credentials.json` on macOS nor repairs a Usage-owned
    /// setup token, so those backends name their own recovery instead.
    static func reauthentication(for locator: CredentialLocator) -> ReauthAction? {
        switch locator.kind {
        case .keychain:
            ReauthAction(summary: "Sign in to Claude Code again, then refresh.", command: "claude")
        case .file:
            ReauthAction(
                summary: "Restore or replace this profile's .credentials.json, then refresh."
            )
        case .appKeychain:
            ReauthAction(summary: "Replace this Claude setup token in Settings, then refresh.")
        case .githubCLI:
            nil
        }
    }

    /// Attaches the locator's recovery instruction to the failures only the credential owner can
    /// clear.
    static func annotated(_ error: any Error, for locator: CredentialLocator) -> UsageError {
        let usage = UsageError.normalized(error)
        switch usage.category {
        case .authenticationExpired, .credentialUnavailable:
            guard let action = Self.reauthentication(for: locator) else { return usage }
            return usage.offering(action)
        default:
            return usage
        }
    }

    /// The Claude Code Keychain account for one root, or nothing when its derived service holds no
    /// row.
    ///
    /// The slot is the root's stable identity, shared with the file and setup-token backends, so
    /// an account keeps its history when its credential moves between stores. The locator carries
    /// the newest row's persistent reference and the document path of the bearer token — the same
    /// payload shape the credential file holds, which is also where the plan label comes from.
    private static func claudeCodeKeychainAccount(
        in root: ProfileRootLocation,
        using context: ProviderContext
    ) async -> ProviderAccount? {
        let namespace = ClaudeCodeKeychain.namespace(
            for: root.directory,
            homeDirectory: context.fileSystem.homeDirectory
        )
        let slots = (try? await context.credentials.slots(in: namespace)) ?? []
        guard let descriptor = slots.first else { return nil }
        let slot = Self.slot(for: root.directory)
        return ProviderAccount(
            key: AccountKey(providerID: id, accountID: .credentialSlot(provider: id, slot: slot)),
            slot: slot,
            locator: CredentialLocator(
                kind: .keychain,
                identifier: descriptor.locator.identifier,
                path: ClaudeCredentialFile.secretPath
            ),
            profileRootID: root.id,
            displayName: root.label,
            availability: .active
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

    private static func setupTokenAccount(
        descriptor: CredentialSlotDescriptor,
        root: ProfileRootLocation
    ) -> ProviderAccount {
        let slot = Self.slot(for: root.directory)
        return ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .credentialSlot(provider: id, slot: slot)
            ),
            slot: slot,
            locator: descriptor.locator,
            profileRootID: root.id,
            displayName: root.label,
            availability: .active
        )
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

    private func fetchSetupTokenUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        let response = try await context.credentials.withCredential(at: account.locator) {
            credential in
            try await context.http.send(
                credential.authorizing(Self.setupTokenProbeRequest(), with: .bearer)
            )
        }

        // A quota rejection can still carry the very headers this source exists to measure.
        // Authentication and server failures remain authoritative even if they carry stale headers.
        if response.status == 429 {
            if let report = try? ClaudeRateLimitHeaders.report(
                from: response,
                account: account,
                capturedAt: context.clock.now
            ) {
                return report
            }
            throw UsageError.from(response, now: context.clock.now)
        }
        guard response.isSuccess else {
            throw UsageError.from(response, now: context.clock.now)
        }
        return try ClaudeRateLimitHeaders.report(
            from: response,
            account: account,
            capturedAt: context.clock.now
        )
    }
}
