import Foundation

/// When one account should be refreshed next.
///
/// A pure function of `AccountRefreshInput` — no clock read, no I/O, no stored state. That is the
/// whole point: refresh timing is the part of an agent-usage app that is hardest to debug, and this
/// makes every rule above assertable in a unit test instead of an offline replay harness.
/// A faster popover-present cadence is deliberately absent. It depends on `MenuBarExtra` content
/// appearance callbacks pairing reliably, and that has never been measured — no agent can click a
/// status item, so `docs/menu-bar-lifecycle.md` still has an empty results table. An unmeasured
/// appearance signal that sticks "present" would pin every account to the fast cadence forever, so
/// the plan gates the input on that table. `PopoverRoot` still records appearances for the human
/// running the spike; nothing feeds them into scheduling.
public enum RefreshPolicy {
    /// The one provider-facing cadence, until the lifecycle spike says a second one can be
    /// trusted.
    public static let idleInterval = Duration.seconds(300)
    /// Base cadence for retrying a credential that vanished from under its cached locator — an
    /// agent rotating its Keychain item on token refresh. The retry costs no provider request and
    /// the rediscovery beside it is what repairs the locator, so recovery is fast; the doubling
    /// and the ceiling still apply.
    public static let credentialRecoveryInterval = Duration.seconds(30)
    /// Upper bound on failure backoff.
    public static let backoffCeiling = Duration.seconds(1_800)
    /// How long after a window's reset instant the refresh that observes it happens.
    public static let resetLead = Duration.seconds(30)
    /// Floor under every delay. Never zero, so a schedule can never busy-loop.
    public static let minimumDelay = Duration.seconds(1)
    /// Upper bound on per-account jitter.
    public static let maximumJitter = Duration.seconds(30)

    private static let jitterFraction = 0.1
    private static let jitterDomain = "dev.blacktop.Usage/RefreshJitter/v1"
    /// Caps the backoff exponent well before `Duration` arithmetic could overflow. The ceiling
    /// bites long before this does.
    private static let maximumDoublings = 10

    /// The delay from `input.now` until this account's next refresh.
    ///
    /// Always positive. Never shorter than an active `Retry-After`, whatever else applies.
    ///
    /// The reset wake may pull a failure-stretched backoff forward, but never below the idle
    /// cadence: no fetch that costs a provider request happens sooner than five minutes after the
    /// previous attempt. Claude's usage endpoint rate-limits aggressively with no usable
    /// `Retry-After` (anthropics/claude-code#31637, #30930), so the floor is a hard property of
    /// the schedule rather than a per-provider courtesy. Credential-recovery retries stay exempt:
    /// they fail before any HTTP request exists.
    public static func nextDelay(for input: AccountRefreshInput) -> Duration {
        let cadence = cadence(for: input)
        var shortened = min(cadence, resetWake(for: input) ?? cadence)
        if !input.isCredentialRecovery {
            shortened = max(shortened, idleInterval)
        }
        let honoured = max(shortened, input.retryAdvice?.delay ?? .zero)
        return max(minimumDelay, honoured + jitter(for: input.key, of: honoured))
    }

    /// Base cadence, doubled once per consecutive failure and capped at the ceiling. A failure
    /// that never left the machine backs off from the short credential-recovery base instead.
    private static func cadence(for input: AccountRefreshInput) -> Duration {
        guard input.consecutiveFailures > 0 else { return idleInterval }
        let base = input.isCredentialRecovery ? credentialRecoveryInterval : idleInterval
        let doublings = min(input.consecutiveFailures - 1, maximumDoublings)
        return min(base * (1 << doublings), backoffCeiling)
    }

    /// Time until shortly after the nearest reset still in the future, or `nil` when every known
    /// reset has already happened.
    private static func resetWake(for input: AccountRefreshInput) -> Duration? {
        guard let next = input.resetDates.filter({ $0 > input.now }).min() else { return nil }
        return .seconds(next.timeIntervalSince(input.now)) + resetLead
    }

    /// A deterministic offset, unique per account and bounded by `maximumJitter`, that keeps every
    /// account of one provider from waking in the same instant.
    ///
    /// Additive, so jitter can never pull a refresh inside a cooldown it would otherwise respect.
    private static func jitter(for key: AccountKey, of delay: Duration) -> Duration {
        let span = min(.seconds(delay.totalSeconds * jitterFraction), maximumJitter)
        return .seconds(span.totalSeconds * fraction(of: key))
    }

    /// A stable `0...1` value derived from the account identity. Deliberately not `hashValue`,
    /// which is seeded per process and would move every launch.
    private static func fraction(of key: AccountKey) -> Double {
        let digest = DomainDigest.hex(
            domain: jitterDomain,
            fields: [key.providerID.rawValue, key.accountID.rawValue]
        )
        guard let byte = UInt8(digest.prefix(2), radix: 16) else { return 0 }
        return Double(byte) / Double(UInt8.max)
    }
}
