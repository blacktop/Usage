import Foundation

/// One account's report, paired with the secret-free descriptor it was fetched for.
public struct CollectedAccount: Sendable, Hashable {
    public let account: ProviderAccount
    public let report: UsageReport

    public init(account: ProviderAccount, report: UsageReport) {
        self.account = account
        self.report = report
    }
}

/// One failure, attributed to an account when discovery got far enough to name one.
public struct CollectedFailure: Sendable, Hashable {
    public let providerID: ProviderID
    public let accountID: AccountID?
    public let error: UsageError

    public init(providerID: ProviderID, accountID: AccountID?, error: UsageError) {
        self.providerID = providerID
        self.accountID = accountID
        self.error = error
    }
}

/// The result of asking a set of providers for their usage.
///
/// Successes and failures are both first-class: a multi-provider run is routinely a partial
/// success, and a provider that could not answer is a fact the caller has to render, not an
/// exception that discards its siblings' answers.
public struct UsageCollection: Sendable, Hashable {
    /// How completely the run answered, and the process exit status that reports it.
    public enum Outcome: Int32, Sendable, Hashable, CaseIterable {
        /// Every requested provider answered for every account it discovered.
        case complete = 0
        /// No requested provider produced a report.
        case none = 1
        /// Some accounts answered and some did not.
        case partial = 2
    }

    public let requested: [ProviderID]
    public let accounts: [CollectedAccount]
    public let failures: [CollectedFailure]

    public init(
        requested: [ProviderID],
        accounts: [CollectedAccount],
        failures: [CollectedFailure]
    ) {
        self.requested = requested
        self.accounts = accounts
        self.failures = failures
    }

    /// Complete demands both halves: every requested provider reported, and nothing failed. An
    /// account that failed inside an otherwise healthy provider is still a partial answer.
    public var outcome: Outcome {
        let answered = Set(accounts.map(\.report.accountKey.providerID))
        if accounts.isEmpty { return .none }
        if failures.isEmpty, answered.count == Set(requested).count { return .complete }
        return .partial
    }

    public func output(generatedAt: Date) -> UsageOutputV1 {
        UsageOutputV1(
            generatedAt: generatedAt,
            accounts: accounts.map {
                UsageOutputV1.Account(
                    label: $0.account.displayName,
                    report: UsageReportDTO($0.report)
                )
            },
            failures: failures.map {
                UsageOutputV1.Failure(
                    providerID: $0.providerID,
                    accountID: $0.accountID,
                    error: $0.error
                )
            }
        )
    }
}
