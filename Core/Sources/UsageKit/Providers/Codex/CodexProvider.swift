import Foundation

/// Codex / ChatGPT, read through the Codex CLI's own `auth.json`, one per configured root.
///
/// Read-only: Usage never refreshes the OAuth token, never rewrites `auth.json`, and never runs the
/// `codex` binary. An expired credential surfaces `.authenticationExpired` carrying `codex login`,
/// and the user runs it themselves.
public struct CodexProvider: Provider {
    public static let id = ProviderID("codex")

    static let usageURL = StaticURL.make("https://chatgpt.com/backend-api/wham/usage")
    static let slotSource = "codex.auth-json"

    /// The instruction attached to every failure only the Codex CLI can clear.
    static let reauthentication = ReauthAction(
        summary: "Sign in to Codex again, then refresh.",
        command: "codex login"
    )

    public let displayName = "Codex"
    public let dashboardURL = StaticURL.make("https://chatgpt.com/codex/settings/usage")

    public init() {}

    /// One account per enabled configured root with file- or Keychain-backed CLI authentication.
    ///
    /// Codex's direct Keychain backend stores the same serialized `auth.json` document under
    /// service `Codex Auth`; its account attribute is a SHA-256-derived identity for `CODEX_HOME`.
    /// That makes lookup root-scoped rather than a host-wide fallback. Enumeration is attributes
    /// only and a *usable* file keeps precedence: a file that exists but carries no OAuth tokens is
    /// not authentication, so the root's Keychain row is still consulted before that file is
    /// reported as the account's unavailable source.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        let roots = try await context.enabledProfileRoots(for: Self.id)
        let fileAccounts = roots.map { Self.fileAccount(in: $0, using: context) }
        guard fileAccounts.contains(where: { $0?.availability != .active }) else {
            return fileAccounts.compactMap { $0 }
        }

        let namespace = CredentialLocator(
            kind: .keychain, identifier: CodexAuthFile.keychainService)
        let keychainSlots = (try? await context.credentials.slots(in: namespace)) ?? []
        return zip(roots, fileAccounts).compactMap { root, fileAccount in
            if let fileAccount, fileAccount.availability == .active { return fileAccount }
            let expectedAccount = CodexAuthFile.keychainAccount(root: root.directory)
            guard
                let descriptor = keychainSlots.first(where: {
                    $0.slot.opaqueID == expectedAccount
                })
            else { return fileAccount }
            return Self.keychainAccount(descriptor: descriptor, root: root)
        }
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        do {
            return try await Self.report(for: account, using: context)
        } catch {
            throw Self.annotated(error)
        }
    }

    /// The usage request, minus authorization.
    ///
    /// `ChatGPT-Account-Id` is omitted entirely when no account identifier is known, matching the
    /// Codex CLI: sending it empty is a different request, not a neutral one.
    ///
    /// The endpoint takes neither `OpenAI-Beta` nor `originator`. Those two headers belong to the
    /// reset-credits route; whether the usage route tolerates them is unverified, so the
    /// known-working header set is sent instead.
    static func usageRequest(chatGPTAccountID: String?) -> HTTPRequest {
        var headers = [
            "Accept": "application/json",
            "User-Agent": UsageKitInfo.userAgent,
        ]
        if let chatGPTAccountID, !chatGPTAccountID.isEmpty {
            headers["ChatGPT-Account-Id"] = chatGPTAccountID
        }
        return HTTPRequest(method: .get, url: usageURL, headers: headers)
    }

    static func locator(at url: URL) -> CredentialLocator {
        CredentialLocator(
            kind: .file,
            identifier: url.standardizedFileURL.path(percentEncoded: false),
            path: CodexAuthFile.secretPath
        )
    }

    private static func report(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        let result = try await context.credentials.withCredential(at: account.locator) {
            credential in
            let metadata =
                try credential.metadata {
                    (data: Data) throws(UsageError) -> CodexAuthMetadata in
                    try CodexAuthFile.parse(data, kind: account.locator.kind)
                } ?? fileMetadata(for: account, using: context)
            let request = usageRequest(chatGPTAccountID: metadata?.accountID)
            let response = try await context.http.send(
                credential.authorizing(request, with: .bearer)
            )
            return CredentialOperationResponse(response: response, metadata: metadata)
        }
        guard result.response.isSuccess else {
            throw UsageError.from(result.response, now: context.clock.now)
        }
        return try CodexUsageMapper.report(
            from: CodexUsageResponse.decode(result.response.body),
            account: account,
            fallbackPlan: result.metadata?.planType,
            capturedAt: context.clock.now
        )
    }

    /// The failure with `codex login` attached, when running it is what would clear the failure.
    ///
    /// A rate limit, a transport failure, and an unreadable response are all left alone: telling
    /// someone to sign in again when the network is down sends them to fix the wrong thing.
    private static func annotated(_ error: any Error) -> UsageError {
        let usage = UsageError.normalized(error)
        switch usage.category {
        case .authenticationExpired, .credentialUnavailable:
            return usage.offering(reauthentication)
        default:
            return usage
        }
    }

    /// The account one root describes, or nothing at all when the root holds no `auth.json`.
    ///
    /// A root without the file is not an unusable account, it is a root Codex was never signed in
    /// under. A file that is present but unparsable is the opposite: a slot that exists and cannot
    /// be used, which is worth showing.
    private static func fileAccount(
        in root: ProfileRootLocation,
        using context: ProviderContext
    ) -> ProviderAccount? {
        let url = CodexAuthFile.url(root: root.directory)
        guard context.fileSystem.fileExists(at: url),
            let data = try? context.fileSystem.read(contentsOf: url)
        else { return nil }
        return account(in: root, at: url, metadata: try? CodexAuthFile.parse(data))
    }

    /// Re-reads the credential file for the request's non-secret metadata.
    ///
    /// Only reached when the credential source handed back no document — the production file source
    /// always does, so this costs nothing on the shipped path. Read fresh rather than cached at
    /// discovery, because the Codex CLI rewrites the file whenever it refreshes, and a cached
    /// `account_id` from an earlier login would address the wrong workspace.
    private static func fileMetadata(
        for account: ProviderAccount,
        using context: ProviderContext
    ) -> CodexAuthMetadata? {
        guard account.locator.kind == .file else { return nil }
        let url = URL(filePath: account.locator.identifier)
        guard let data = try? context.fileSystem.read(contentsOf: url) else { return nil }
        return try? CodexAuthFile.parse(data)
    }

    private static func keychainAccount(
        descriptor: CredentialSlotDescriptor,
        root: ProfileRootLocation
    ) -> ProviderAccount {
        let slot = Self.slot(for: root.directory)
        let locator = CredentialLocator(
            kind: .keychain,
            identifier: descriptor.locator.identifier,
            path: CodexAuthFile.secretPath
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

    /// The descriptor for one credential file.
    ///
    /// Identity is unchanged by configured roots: a file that names an `account_id` still
    /// reconciles onto the canonical identity, so the same workspace reached through two roots is
    /// one account rather than two. Without one, the slot — and therefore the identity — is the
    /// file's own path, which is stable for as long as the root points where it points.
    private static func account(
        in root: ProfileRootLocation,
        at url: URL,
        metadata: CodexAuthMetadata?
    ) -> ProviderAccount {
        let slot = Self.slot(for: root.directory)
        let accountID =
            metadata?.accountID.map { AccountID.canonical(provider: id, canonicalID: $0) }
            ?? AccountID.credentialSlot(provider: id, slot: slot)
        return ProviderAccount(
            key: AccountKey(providerID: id, accountID: accountID),
            slot: slot,
            locator: locator(at: url),
            profileRootID: root.id,
            displayName: root.label,
            availability: metadata == nil ? .unavailable : .active
        )
    }

    /// Stable logical slot for a configured root, independent of its current credential store.
    private static func slot(for root: URL) -> CredentialSlotID {
        let path = CodexAuthFile.url(root: root).standardizedFileURL.path(percentEncoded: false)
        return CredentialSlotID(source: slotSource, opaqueID: path)
    }
}
