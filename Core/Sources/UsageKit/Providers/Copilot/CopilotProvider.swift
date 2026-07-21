import Foundation

/// GitHub Copilot, read through the credential files the Copilot editor plugin and CLI keep under
/// `~/.config/github-copilot`.
///
/// Read-only: Usage runs no device flow, writes no Keychain item, and never rewrites those files.
/// The `gho_` tokens they hold have no refresh token, so there would be nothing to refresh even if
/// we wanted to. Reauthentication belongs to whichever tool wrote the file.
public struct CopilotProvider: Provider {
    public static let id = ProviderID("copilot")

    /// The request identifies as the Copilot chat extension. The endpoint is editor-internal and
    /// its behaviour under a truthful `Usage/<version>` agent is unknown, so the known-working
    /// identity is sent. Bumping the plugin generation is a single edit here.
    static let editorVersion = "vscode/1.96.2"
    static let editorPluginVersion = "copilot-chat/0.26.7"
    static let userAgent = "GitHubCopilotChat/0.26.7"
    static let apiVersion = "2025-04-01"
    static let slotSourcePrefix = "copilot."

    public let displayName = "GitHub Copilot"
    public let dashboardURL = StaticURL.make("https://github.com/settings/copilot")

    public init() {}

    /// Enumerates every entry across the credential files, most authoritative file first.
    ///
    /// One GitHub host appears in at most one account: `apps.json` beats `hosts.json` beats
    /// `oauth.json`, matching the order the tools themselves migrated through.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        var claimedHosts: Set<String> = []
        for fileName in CopilotCredentialFiles.fileNames {
            let url = CopilotCredentialFiles.url(
                home: context.fileSystem.homeDirectory,
                fileName: fileName
            )
            guard context.fileSystem.fileExists(at: url),
                let data = try? context.fileSystem.read(contentsOf: url)
            else { continue }
            for slot in CopilotCredentialFiles.slots(in: data, fileName: fileName)
            where !claimedHosts.contains(slot.host) && Self.usageURL(host: slot.host) != nil {
                claimedHosts.insert(slot.host)
                accounts.append(Self.account(for: slot, at: url))
            }
        }
        return accounts
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        guard let request = Self.usageRequest(host: Self.host(of: account)) else {
            throw UsageError.providerUnavailable()
        }
        let response = try await context.credentials.withCredential(at: account.locator) {
            credential in
            try await context.http.send(credential.authorizing(request, with: .token))
        }
        guard response.isSuccess else {
            throw Self.error(from: response, now: context.clock.now)
        }
        return try CopilotUsageMapper.report(
            from: CopilotUsageResponse.decode(response.body),
            account: account,
            capturedAt: context.clock.now
        )
    }

    /// The usage endpoint for one GitHub host, or `nil` when that host cannot be trusted as an
    /// authority.
    ///
    /// The host is a key from a file another tool writes, and the request built from it is stamped
    /// with a live `gho_` token, so the authority is checked twice: the string must be a bare
    /// authority, and the URL that comes out must still address exactly that authority with no
    /// userinfo. A host that fails either check yields no account and no request.
    static func usageURL(host: String) -> URL? {
        let apiHost = CopilotCredentialFiles.apiHost(for: host)
        guard CopilotCredentialFiles.isBareAuthority(apiHost),
            let url = URL(string: "https://\(apiHost)/copilot_internal/user"),
            url.user() == nil, url.password() == nil,
            url.host(percentEncoded: false) == apiHost.split(separator: ":").first.map(String.init)
        else { return nil }
        return url
    }

    /// The usage request, minus authorization.
    ///
    /// Authorization uses GitHub's `token` scheme, not `Bearer`, and carries the raw OAuth token
    /// rather than an exchanged short-lived Copilot token.
    static func usageRequest(host: String) -> HTTPRequest? {
        guard let url = usageURL(host: host) else { return nil }
        return HTTPRequest(
            method: .get,
            url: url,
            headers: [
                "Accept": "application/json",
                "Editor-Version": editorVersion,
                "Editor-Plugin-Version": editorPluginVersion,
                "User-Agent": userAgent,
                "X-GitHub-Api-Version": apiVersion,
            ]
        )
    }

    /// GitHub overloads 403 across a revoked token, a seat without Copilot, and secondary rate
    /// limiting. Telling a throttled user to sign in again is advice they cannot act on, so a 403
    /// carrying a rate-limit signal is classified as throttling instead.
    static func error(from response: HTTPResponse, now: Date) -> UsageError {
        guard response.status == 403, isRateLimited(response) else {
            return UsageError.from(response, now: now)
        }
        return UsageError.from(response, category: .rateLimited, now: now)
    }

    private static func isRateLimited(_ response: HTTPResponse) -> Bool {
        response.headerValue("Retry-After") != nil
            || response.headerValue("x-ratelimit-remaining") == "0"
    }

    /// Recovers the GitHub host from the account descriptor, which is the only thing carried
    /// forward from discovery.
    static func host(of account: ProviderAccount) -> String {
        let fileName = String(account.slot.source.dropFirst(slotSourcePrefix.count))
        return CopilotCredentialFiles.host(forKey: account.slot.opaqueID, fileName: fileName)
    }

    private static func account(for slot: CopilotCredentialSlot, at url: URL) -> ProviderAccount {
        let slotID = CredentialSlotID(
            source: slotSourcePrefix + slot.fileName,
            opaqueID: slot.mapKey
        )
        return ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .credentialSlot(provider: id, slot: slotID)
            ),
            slot: slotID,
            locator: CredentialLocator(
                kind: .file,
                identifier: url.standardizedFileURL.path(percentEncoded: false),
                path: [slot.mapKey, slot.tokenField]
            ),
            displayName: slot.login.map { "\($0)@\(slot.host)" },
            availability: .active
        )
    }
}
