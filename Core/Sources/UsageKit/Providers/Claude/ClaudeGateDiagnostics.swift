import Foundation

/// One root's Gate A answer: whether the derived service name matched any Keychain row.
///
/// The profile index is the one-based Settings order. Nothing here names the root, the service, an
/// account, a row count, or a reference — match/no-match and the raw `OSStatus` are the whole
/// report.
public struct ClaudeKeychainAddressOutcome: Sendable, Equatable {
    public let profileIndex: Int
    public let matched: Bool
    public let status: Int32

    public init(profileIndex: Int, matched: Bool, status: Int32) {
        self.profileIndex = profileIndex
        self.matched = matched
        self.status = status
    }
}

/// The result of one Gate B leg: one credential resolution and at most one usage request.
public struct ClaudeUsageDiagnosticResult: Sendable, Equatable {
    public enum Source: String, Sendable, CaseIterable {
        case claudeCode = "claude-code"
        case setupToken = "setup-token"
    }

    /// How the credential read ended, reduced to the three words the gate is allowed to record.
    public enum CredentialOutcome: String, Sendable {
        case resolved
        case interactionRequired
        case unavailable
    }

    public let source: Source
    public let credential: CredentialOutcome
    /// Whether the usage request left the machine. False on any local credential failure.
    public let requestSent: Bool
    /// The response status, or `nil` when no request occurred or the transport failed.
    public let httpStatus: Int?
    public let sessionWindowDecoded: Bool?
    public let weeklyWindowDecoded: Bool?
}

/// A Gate A or Gate B run that ended before it could measure anything.
public enum ClaudeGateDiagnosticFailure: Error, Equatable {
    case storageUnreadable
    case profileIndexOutOfRange(configured: Int)
}

/// The user-run acceptance gates for the Claude metering plan.
///
/// Gate A answers whether the derived per-root service naming scheme matches this host's Keychain.
/// Gate B answers whether one resolved credential can read `/api/oauth/usage`. Both emit only the
/// allowlisted, redacted fields their report types carry; neither writes to the unified log.
public enum ClaudeGateDiagnostics {
    /// Gate A: one enumeration-only query per enabled Claude root, in Settings order.
    ///
    /// The default `enumerate` sends the production enumeration query under the no-UI policy, which
    /// is attributes-only by construction and therefore cannot prompt or read a payload.
    public static func keychainAddressOutcomes(
        context: ProviderContext,
        enumerate: (String) -> KeychainEnumerationOutcome = { service in
            KeychainProbe().enumerate(service: service, allowsCredentialUI: false)
        }
    ) async throws(ClaudeGateDiagnosticFailure) -> [ClaudeKeychainAddressOutcome] {
        try await claudeRoots(context: context).enumerated().map { index, root in
            let outcome = enumerate(
                ClaudeCodeKeychain.service(
                    for: root.directory,
                    homeDirectory: context.fileSystem.homeDirectory
                )
            )
            return ClaudeKeychainAddressOutcome(
                profileIndex: index + 1,
                matched: outcome.category == .success && outcome.itemCount > 0,
                status: outcome.status
            )
        }
    }

    /// The Gate A report, one line per root, carrying only index, match, and status.
    public static func lines(for outcomes: [ClaudeKeychainAddressOutcome]) -> [String] {
        outcomes.map {
            "profile=\($0.profileIndex) match=\($0.matched ? "yes" : "no") status=\($0.status)"
        }
    }

    /// Gate B: resolve one credential and send at most one usage request.
    ///
    /// A local credential failure ends the leg before any request exists — the report then carries
    /// no HTTP fact at all, so a signing or approval problem can never masquerade as an endpoint
    /// rejection.
    public static func usageResult(
        context: ProviderContext,
        profileIndex: Int,
        source: ClaudeUsageDiagnosticResult.Source
    ) async throws(ClaudeGateDiagnosticFailure) -> ClaudeUsageDiagnosticResult {
        let roots = try await claudeRoots(context: context)
        guard profileIndex >= 1, profileIndex <= roots.count else {
            throw .profileIndexOutOfRange(configured: roots.count)
        }
        let root = roots[profileIndex - 1]
        guard let locator = await locator(for: source, root: root, context: context) else {
            return failed(source: source, credential: .unavailable)
        }
        return await measure(locator: locator, source: source, context: context)
    }

    /// The one-line Gate B report.
    public static func line(for result: ClaudeUsageDiagnosticResult) -> String {
        var parts = [
            "source=\(result.source.rawValue)",
            "credential=\(result.credential.rawValue)",
        ]
        if result.requestSent {
            parts.append("http=\(result.httpStatus.map(String.init) ?? "transport-failure")")
        }
        if let session = result.sessionWindowDecoded, let weekly = result.weeklyWindowDecoded {
            parts.append("session=\(session ? "yes" : "no")")
            parts.append("weekly=\(weekly ? "yes" : "no")")
        }
        return parts.joined(separator: " ")
    }

    private static func claudeRoots(
        context: ProviderContext
    ) async throws(ClaudeGateDiagnosticFailure) -> [ProfileRootLocation] {
        guard let roots = try? await context.enabledProfileRoots(for: ClaudeProvider.id) else {
            throw .storageUnreadable
        }
        return roots
    }

    private static func locator(
        for source: ClaudeUsageDiagnosticResult.Source,
        root: ProfileRootLocation,
        context: ProviderContext
    ) async -> CredentialLocator? {
        switch source {
        case .setupToken:
            return ClaudeSetupTokenCredential.locator(for: root.id)
        case .claudeCode:
            let namespace = ClaudeCodeKeychain.namespace(
                for: root.directory,
                homeDirectory: context.fileSystem.homeDirectory
            )
            let slots = (try? await context.credentials.slots(in: namespace)) ?? []
            guard let descriptor = slots.first else { return nil }
            return CredentialLocator(
                kind: .keychain,
                identifier: descriptor.locator.identifier,
                path: ClaudeCredentialFile.secretPath
            )
        }
    }

    private static func measure(
        locator: CredentialLocator,
        source: ClaudeUsageDiagnosticResult.Source,
        context: ProviderContext
    ) async -> ClaudeUsageDiagnosticResult {
        var requestSent = false
        do {
            let response: HTTPResponse = try await context.credentials.withCredential(at: locator) {
                credential in
                requestSent = true
                return try await context.http.send(
                    credential.authorizing(ClaudeProvider.usageRequest(), with: .bearer)
                )
            }
            let decoded = response.isSuccess ? try? ClaudeUsageResponse.decode(response.body) : nil
            return ClaudeUsageDiagnosticResult(
                source: source,
                credential: .resolved,
                requestSent: true,
                httpStatus: response.status,
                sessionWindowDecoded: response.isSuccess ? sessionDecoded(decoded) : nil,
                weeklyWindowDecoded: response.isSuccess ? weeklyDecoded(decoded) : nil
            )
        } catch {
            if requestSent {
                return ClaudeUsageDiagnosticResult(
                    source: source,
                    credential: .resolved,
                    requestSent: true,
                    httpStatus: nil,
                    sessionWindowDecoded: nil,
                    weeklyWindowDecoded: nil
                )
            }
            let outcome: ClaudeUsageDiagnosticResult.CredentialOutcome =
                UsageError.normalized(error).category == .interactionRequired
                ? .interactionRequired : .unavailable
            return failed(source: source, credential: outcome)
        }
    }

    private static func failed(
        source: ClaudeUsageDiagnosticResult.Source,
        credential: ClaudeUsageDiagnosticResult.CredentialOutcome
    ) -> ClaudeUsageDiagnosticResult {
        ClaudeUsageDiagnosticResult(
            source: source,
            credential: credential,
            requestSent: false,
            httpStatus: nil,
            sessionWindowDecoded: nil,
            weeklyWindowDecoded: nil
        )
    }

    private static func sessionDecoded(_ response: ClaudeUsageResponse?) -> Bool {
        guard let response else { return false }
        return response.fiveHour != nil
            || response.limits.contains { $0.kind == "session" && $0.percent != nil }
    }

    private static func weeklyDecoded(_ response: ClaudeUsageResponse?) -> Bool {
        guard let response else { return false }
        return response.sevenDay != nil
            || response.limits.contains { $0.kind == "weekly_all" && $0.percent != nil }
    }
}
