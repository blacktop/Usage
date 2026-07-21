import Foundation

/// The CLI's machine-readable envelope.
///
/// A versioned contract of its own, so `usage json` never exposes the in-memory model's
/// synthesized `Codable` as a permanent public interface. Successful accounts and per-account
/// failures are both present, because a multi-provider run is routinely a partial success.
public struct UsageOutputV1: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public struct Account: Sendable, Hashable, Codable {
        /// Non-secret display label, when the provider offered one.
        public let label: String?
        public let report: UsageReportDTO

        public init(label: String?, report: UsageReportDTO) {
            self.label = label
            self.report = report
        }
    }

    public struct Failure: Sendable, Hashable, Codable {
        /// What the owning agent has to be told to do. Present only when running it would clear
        /// the failure, so a consumer can offer the action without re-deriving the rule.
        public struct Reauth: Sendable, Hashable, Codable {
            public let summary: String
            public let command: String?

            public init(_ action: ReauthAction) {
                summary = action.summary
                command = action.command
            }
        }

        public let providerID: String
        public let accountID: String?
        public let category: String
        /// Already redacted by `UsageError`; safe to print.
        public let message: String
        public let retryAfterSeconds: Int64?
        public let retryScope: String?
        public let reauth: Reauth?

        public init(providerID: ProviderID, accountID: AccountID?, error: UsageError) {
            self.providerID = providerID.rawValue
            self.accountID = accountID?.rawValue
            category = error.category.rawValue
            message = error.message
            retryAfterSeconds = error.retry.map { $0.delay.components.seconds }
            retryScope = error.retry?.scope.rawValue
            reauth = error.reauthentication.map(Reauth.init)
        }
    }

    public let schemaVersion: Int
    public let generatedAt: Int64
    public let accounts: [Account]
    public let failures: [Failure]

    public init(generatedAt: Date, accounts: [Account], failures: [Failure]) {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = EpochSeconds.from(generatedAt)
        self.accounts = accounts
        self.failures = failures
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, accounts, failures
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        try SchemaVersion.check(version, upTo: Self.currentSchemaVersion, in: container)
        schemaVersion = version
        generatedAt = try container.decode(Int64.self, forKey: .generatedAt)
        accounts = try container.decode([Account].self, forKey: .accounts)
        failures = try container.decode([Failure].self, forKey: .failures)
    }
}
