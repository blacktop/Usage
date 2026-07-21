import Foundation

/// Everything the UI knows about one account.
///
/// Stale-while-revalidate is a property of this type: `refreshPhase` and `lastError` move
/// independently of `report`, so a loading or failed refresh never blanks the last good data.
/// Only an explicit invalidation removes a report.
public struct AccountState: Sendable, Hashable, Identifiable {
    public enum RefreshPhase: String, Sendable, Hashable, Codable, CaseIterable {
        case idle
        case scheduled
        case loading
    }

    public var id: AccountKey { account.key }

    public let account: AccountProjection
    public let report: UsageReport?
    public let refreshPhase: RefreshPhase
    public let lastError: UsageError?
    public let lastAttemptAt: Date?

    public init(
        account: AccountProjection,
        report: UsageReport? = nil,
        refreshPhase: RefreshPhase = .idle,
        lastError: UsageError? = nil,
        lastAttemptAt: Date? = nil
    ) {
        self.account = account
        self.report = report
        self.refreshPhase = refreshPhase
        self.lastError = lastError
        self.lastAttemptAt = lastAttemptAt
    }

    public func withAccount(_ account: AccountProjection) -> AccountState {
        copy(account: account)
    }

    public func scheduled() -> AccountState {
        copy(refreshPhase: .scheduled)
    }

    public func beganRefresh(at date: Date) -> AccountState {
        copy(refreshPhase: .loading, lastAttemptAt: .some(date))
    }

    /// Applies a successful refresh. An out-of-order response older than the report already held
    /// is discarded rather than moving the account backwards in time.
    public func succeeded(with report: UsageReport, at date: Date) -> AccountState {
        let isStale = self.report.map { report.capturedAt < $0.capturedAt } ?? false
        return AccountState(
            account: account,
            report: isStale ? self.report : report,
            refreshPhase: .idle,
            lastError: nil,
            lastAttemptAt: date
        )
    }

    public func failed(with error: UsageError, at date: Date) -> AccountState {
        AccountState(
            account: account,
            report: report,
            refreshPhase: .idle,
            lastError: error,
            lastAttemptAt: date
        )
    }

    /// Drops cached usage. The only transition allowed to do so.
    public func invalidated() -> AccountState {
        AccountState(account: account, refreshPhase: .idle, lastAttemptAt: lastAttemptAt)
    }

    private func copy(
        account: AccountProjection? = nil,
        refreshPhase: RefreshPhase? = nil,
        lastAttemptAt: Date?? = nil
    ) -> AccountState {
        AccountState(
            account: account ?? self.account,
            report: report,
            refreshPhase: refreshPhase ?? self.refreshPhase,
            lastError: lastError,
            lastAttemptAt: lastAttemptAt ?? self.lastAttemptAt
        )
    }
}
