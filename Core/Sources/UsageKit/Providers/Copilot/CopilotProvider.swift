import Foundation

/// GitHub Copilot, read through the current CLI credential sources and the files older
/// Copilot clients keep in their configuration directory.
///
/// Read-only: Usage runs no device flow, writes no Keychain item, and never rewrites those files.
/// Reauthentication belongs to whichever tool wrote the credential.
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
    static let globalSlotSourcePrefix = "copilot.global."
    static let cliKeychainService = "copilot-cli"
    static let githubCLIKeychainService = "gh:github.com"

    public let displayName = "GitHub Copilot"
    public let dashboardURL = StaticURL.make("https://github.com/settings/copilot")

    public init() {}

    /// Every usable credential entry below every enabled configured root, in root order.
    ///
    /// The current Copilot CLI checks its own Keychain item and then GitHub CLI authentication
    /// before legacy editor files. Those host-wide sources are attached once, to the first enabled
    /// Copilot root, so adding roots never duplicates the same global credential.
    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        let roots = try await context.enabledProfileRoots(for: Self.id)
        var accounts: [ProviderAccount] = []
        var globalHosts: Set<String> = []
        if let firstRoot = roots.first {
            let globalAccounts = await Self.globalAccounts(
                in: firstRoot,
                using: context
            )
            accounts.append(contentsOf: globalAccounts)
            globalHosts.formUnion(globalAccounts.map(Self.host(of:)))
        }
        for root in roots {
            accounts.append(
                contentsOf: Self.fileAccounts(
                    in: root,
                    excluding: root.id == roots.first?.id ? globalHosts : [],
                    using: context
                )
            )
        }
        return accounts
    }

    /// One root's entries, most authoritative file first.
    ///
    /// A GitHub host appears in at most one account per root: `apps.json` beats `hosts.json` beats
    /// `oauth.json`, matching the order the tools themselves migrated through. Precedence is scoped
    /// to the root and not to the whole run, because two roots both holding `github.com` are two
    /// configured accounts, not the same entry seen twice.
    private static func fileAccounts(
        in root: ProfileRootLocation,
        excluding excludedHosts: Set<String>,
        using context: ProviderContext
    ) -> [ProviderAccount] {
        var accounts: [ProviderAccount] = []
        var claimedHosts = excludedHosts
        for fileName in CopilotCredentialFiles.fileNames {
            let url = CopilotCredentialFiles.url(root: root.directory, fileName: fileName)
            guard context.fileSystem.fileExists(at: url),
                let data = try? context.fileSystem.read(contentsOf: url)
            else { continue }
            for slot in CopilotCredentialFiles.slots(in: data, fileName: fileName)
            where !claimedHosts.contains(slot.host) && usageURL(host: slot.host) != nil {
                claimedHosts.insert(slot.host)
                accounts.append(
                    account(for: slot, at: url, profileRootID: root.id, label: root.label)
                )
            }
        }
        return accounts
    }

    /// Current Copilot CLI authentication, in precedence order: its own host-keyed Keychain rows,
    /// then GitHub CLI's account-keyed rows. Enumeration is attributes-only. GitHub CLI payloads
    /// are resolved by `gh auth token --user`, so Usage neither guesses which row is active nor
    /// asks for direct access to a Keychain item owned by `gh`.
    private static func globalAccounts(
        in root: ProfileRootLocation,
        using context: ProviderContext
    ) async -> [ProviderAccount] {
        let cliNamespace = CredentialLocator(kind: .keychain, identifier: cliKeychainService)
        if let descriptors = try? await context.credentials.slots(in: cliNamespace) {
            let accounts = descriptors.compactMap { descriptor -> ProviderAccount? in
                guard let host = copilotCLIHost(descriptor) else { return nil }
                return globalAccount(descriptor: descriptor, host: host, root: root)
            }
            if !accounts.isEmpty { return accounts }
        }

        let githubNamespace = CredentialLocator(
            kind: .keychain,
            identifier: githubCLIKeychainService
        )
        guard let descriptors = try? await context.credentials.slots(in: githubNamespace) else {
            return []
        }
        return descriptors.compactMap { descriptor in
            guard let login = descriptor.displayName,
                let locator = GitHubCLICredentialSource.locator(login: login)
            else { return nil }
            return globalAccount(
                descriptor: descriptor,
                locator: locator,
                host: CopilotCredentialFiles.defaultHost,
                root: root
            )
        }
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
            try await context.http.send(credential.authorizing(request, with: .bearer))
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
    /// Authorization uses the `Bearer` scheme used by the current Copilot CLI and carries its
    /// resolved OAuth credential.
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
    ///
    /// The entry's own key is the locator's first path component. The slot identifier cannot be
    /// used for this: it qualifies that key with the file's path so that the same host under two
    /// configured roots stays two accounts.
    static func host(of account: ProviderAccount) -> String {
        if account.slot.source.hasPrefix(globalSlotSourcePrefix) {
            return String(account.slot.source.dropFirst(globalSlotSourcePrefix.count))
        }
        let fileName = String(account.slot.source.dropFirst(slotSourcePrefix.count))
        return CopilotCredentialFiles.host(
            forKey: account.locator.path.first ?? "",
            fileName: fileName
        )
    }

    private static func account(
        for slot: CopilotCredentialSlot,
        at url: URL,
        profileRootID: ProfileRootID,
        label: String
    ) -> ProviderAccount {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let slotID = CredentialSlotID(
            source: slotSourcePrefix + slot.fileName,
            opaqueID: "\(path)#\(slot.mapKey)"
        )
        return ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .credentialSlot(provider: id, slot: slotID)
            ),
            slot: slotID,
            locator: CredentialLocator(
                kind: .file,
                identifier: path,
                path: [slot.mapKey, slot.tokenField]
            ),
            profileRootID: profileRootID,
            displayName: label,
            availability: .active
        )
    }

    private static func globalAccount(
        descriptor: CredentialSlotDescriptor,
        locator: CredentialLocator? = nil,
        host: String,
        root: ProfileRootLocation
    ) -> ProviderAccount {
        let slot = CredentialSlotID(
            source: globalSlotSourcePrefix + host,
            opaqueID: descriptor.slot.opaqueID
        )
        return ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .credentialSlot(provider: id, slot: slot)
            ),
            slot: slot,
            locator: locator ?? descriptor.locator,
            profileRootID: root.id,
            displayName: descriptor.displayName ?? root.label,
            availability: .active
        )
    }

    /// The Copilot CLI stores one row per host with the host in the non-secret account attribute.
    /// A row that does not carry a bare authority is unusable: defaulting it to github.com could
    /// send an enterprise credential to the public API.
    private static func copilotCLIHost(_ descriptor: CredentialSlotDescriptor) -> String? {
        guard let raw = descriptor.displayName?.trimmedNonEmpty else { return nil }
        let host = raw.lowercased()
        guard CopilotCredentialFiles.isBareAuthority(host), usageURL(host: host) != nil else {
            return nil
        }
        return host
    }
}
