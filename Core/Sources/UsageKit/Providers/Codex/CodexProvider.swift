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

    /// One account per enabled configured root that holds an `auth.json`.
    ///
    /// The credential file, and only the credential file. A `Codex Auth` Keychain item exists on
    /// some machines, but nothing documents its payload format and the Codex CLI reference never
    /// reads it. Treating it as another `auth.json` was a guess: a wrong guess sends an
    /// unrecognised payload as a bearer token, and being right would still buy nothing, since an
    /// attributes-only query cannot recover the `account_id` that addresses the right workspace,
    /// nor say which configured root the item belongs to. Reinstate it only with a verified format.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        for root in try await context.enabledProfileRoots(for: Self.id) {
            guard let account = Self.account(in: root, using: context) else { continue }
            accounts.append(account)
        }
        return accounts
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
        let metadata = metadata(for: account, using: context)
        let request = usageRequest(chatGPTAccountID: metadata?.accountID)
        let response = try await context.credentials.withCredential(at: account.locator) {
            credential in
            try await context.http.send(credential.authorizing(request, with: .bearer))
        }
        guard response.isSuccess else {
            throw UsageError.from(response, now: context.clock.now)
        }
        return try CodexUsageMapper.report(
            from: CodexUsageResponse.decode(response.body),
            account: account,
            fallbackPlan: metadata?.planType,
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
    private static func account(
        in root: ProfileRootLocation,
        using context: ProviderContext
    ) -> ProviderAccount? {
        let url = CodexAuthFile.url(root: root.directory)
        guard context.fileSystem.fileExists(at: url),
            let data = try? context.fileSystem.read(contentsOf: url)
        else { return nil }
        return account(
            at: url,
            profileRootID: root.id,
            label: root.label,
            metadata: try? CodexAuthFile.parse(data)
        )
    }

    /// Re-reads the credential file for the request's non-secret metadata.
    ///
    /// Read fresh on every fetch rather than cached at discovery, because the Codex CLI rewrites
    /// the file whenever it refreshes, and a cached `account_id` from an earlier login would
    /// address the wrong workspace.
    private static func metadata(
        for account: ProviderAccount,
        using context: ProviderContext
    ) -> CodexAuthMetadata? {
        guard account.locator.kind == .file else { return nil }
        let url = URL(filePath: account.locator.identifier)
        guard let data = try? context.fileSystem.read(contentsOf: url) else { return nil }
        return try? CodexAuthFile.parse(data)
    }

    /// The descriptor for one credential file.
    ///
    /// Identity is unchanged by configured roots: a file that names an `account_id` still
    /// reconciles onto the canonical identity, so the same workspace reached through two roots is
    /// one account rather than two. Without one, the slot — and therefore the identity — is the
    /// file's own path, which is stable for as long as the root points where it points.
    private static func account(
        at url: URL,
        profileRootID: ProfileRootID,
        label: String,
        metadata: CodexAuthMetadata?
    ) -> ProviderAccount {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let slot = CredentialSlotID(source: slotSource, opaqueID: path)
        let accountID =
            metadata?.accountID.map { AccountID.canonical(provider: id, canonicalID: $0) }
            ?? AccountID.credentialSlot(provider: id, slot: slot)
        return ProviderAccount(
            key: AccountKey(providerID: id, accountID: accountID),
            slot: slot,
            locator: locator(at: url),
            profileRootID: profileRootID,
            displayName: label,
            availability: metadata == nil ? .unavailable : .active
        )
    }
}
