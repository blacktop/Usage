import Foundation

/// Everything `RefreshPolicy` is allowed to look at when it decides when one account is next due.
///
/// The clock is an input rather than something the policy reads, which is what makes the policy a
/// pure function of this value and therefore testable without a scheduler, a harness, or a wait.
public struct AccountRefreshInput: Sendable, Hashable {
    /// How this account's last completed attempt ended.
    public enum Outcome: Sendable, Hashable {
        /// Discovered, never attempted.
        case initial
        case success
        /// The failure verbatim, so its `Retry-After` advice and scope survive into scheduling.
        case failure(UsageError)
    }

    public var key: AccountKey
    public var now: Date
    public var outcome: Outcome
    /// Failures since the last success. Zero after any success.
    public var consecutiveFailures: Int
    /// Reset instants from the account's last good report. Instants already in the past are
    /// ignored: a stale report's reset date must never pull the schedule forward.
    public var resetDates: [Date]

    public init(
        key: AccountKey,
        now: Date,
        outcome: Outcome = .initial,
        consecutiveFailures: Int = 0,
        resetDates: [Date] = []
    ) {
        self.key = key
        self.now = now
        self.outcome = outcome
        self.consecutiveFailures = consecutiveFailures
        self.resetDates = resetDates
    }

    /// The `Retry-After` advice the last failure carried, if it carried one.
    var retryAdvice: UsageError.RetryAdvice? {
        guard case .failure(let error) = outcome else { return nil }
        return error.retry
    }
}
