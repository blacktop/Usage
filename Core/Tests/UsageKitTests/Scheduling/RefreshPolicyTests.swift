import Foundation
import Testing

@testable import UsageKit

@Suite("Refresh policy")
struct RefreshPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func key(_ id: String = "alpha") -> AccountKey {
        AccountKey(
            providerID: ProviderID("stub"),
            accountID: .canonical(provider: ProviderID("stub"), canonicalID: id)
        )
    }

    private func input(
        _ id: String = "alpha",
        outcome: AccountRefreshInput.Outcome = .success,
        failures: Int = 0,
        resets: [Date] = []
    ) -> AccountRefreshInput {
        AccountRefreshInput(
            key: key(id),
            now: now,
            outcome: outcome,
            consecutiveFailures: failures,
            resetDates: resets
        )
    }

    /// The jittered delay always lands in `[base, base + min(10% of base, 30s)]`.
    private func expectWithinJitter(
        _ delay: Duration,
        of base: Duration,
        _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let ceiling = base + min(.seconds(base.totalSeconds * 0.1), RefreshPolicy.maximumJitter)
        #expect(delay >= base, comment, sourceLocation: sourceLocation)
        #expect(delay <= ceiling, comment, sourceLocation: sourceLocation)
    }

    @Test("An idle account uses the five-minute cadence")
    func idleCadence() {
        expectWithinJitter(
            RefreshPolicy.nextDelay(for: input()),
            of: RefreshPolicy.idleInterval,
            "idle accounts refresh every five minutes"
        )
    }

    /// Guards the Phase 0 gate. A popover-present cadence needs `MenuBarExtra` appearance callbacks
    /// to pair reliably, and the results table in docs/menu-bar-lifecycle.md is still empty. Adding
    /// a second cadence before that table is filled in turns this red.
    @Test("Base cadence does not vary with anything but consecutive failures")
    func cadenceHasNoUnmeasuredInputs() {
        let quiet = RefreshPolicy.nextDelay(for: input("same-account"))
        let repeated = RefreshPolicy.nextDelay(for: input("same-account"))
        #expect(quiet == repeated, "the policy is pure, so equal inputs give equal delays")
        expectWithinJitter(quiet, of: RefreshPolicy.idleInterval, "only one base cadence exists")
    }

    @Test("Consecutive failures back off exponentially and stop at the ceiling")
    func failureBackoffReachesTheCeiling() {
        let failure = AccountRefreshInput.Outcome.failure(.transportFailure())
        var previous = Duration.zero
        for count in 1...4 {
            let delay = RefreshPolicy.nextDelay(
                for: input(outcome: failure, failures: count)
            )
            expectWithinJitter(
                delay,
                of: min(
                    RefreshPolicy.idleInterval * (1 << (count - 1)), RefreshPolicy.backoffCeiling),
                "failure \(count) doubles the cadence"
            )
            #expect(delay > previous)
            previous = delay
        }
        let capped = RefreshPolicy.nextDelay(for: input(outcome: failure, failures: 40))
        expectWithinJitter(capped, of: RefreshPolicy.backoffCeiling, "backoff stops at 30 minutes")
    }

    @Test("A Retry-After longer than the cadence is honoured verbatim")
    func retryAfterExtendsTheDelay() {
        let rateLimited = UsageError(
            category: .rateLimited,
            reason: .httpStatus(code: 429),
            retry: UsageError.RetryAdvice(delay: .seconds(900), scope: .account)
        )
        let delay = RefreshPolicy.nextDelay(for: input(outcome: .failure(rateLimited), failures: 1))
        expectWithinJitter(delay, of: .seconds(900), "Retry-After wins over the cadence")
    }

    @Test("A Retry-After shorter than the backoff never shortens it")
    func retryAfterNeverShortensBackoff() {
        let rateLimited = UsageError(
            category: .rateLimited,
            reason: .httpStatus(code: 429),
            retry: UsageError.RetryAdvice(delay: .seconds(5), scope: .account)
        )
        let delay = RefreshPolicy.nextDelay(for: input(outcome: .failure(rateLimited), failures: 3))
        #expect(delay >= RefreshPolicy.idleInterval * 4)
    }

    @Test("A Retry-After survives the reset wake")
    func retryAfterOutranksEveryShortening() {
        let rateLimited = UsageError(
            category: .rateLimited,
            reason: .httpStatus(code: 429),
            retry: UsageError.RetryAdvice(delay: .seconds(600), scope: .account)
        )
        let delay = RefreshPolicy.nextDelay(
            for: input(
                outcome: .failure(rateLimited),
                failures: 1,
                resets: [now.addingTimeInterval(30)]
            )
        )
        #expect(delay >= .seconds(600))
    }

    @Test("The nearest future reset pulls the next refresh just past it")
    func futureResetShortensTheDelay() {
        let delay = RefreshPolicy.nextDelay(
            for: input(
                resets: [
                    now.addingTimeInterval(3_600),
                    now.addingTimeInterval(120),
                    now.addingTimeInterval(600),
                ]
            )
        )
        expectWithinJitter(delay, of: .seconds(150), "wake 30s after the nearest reset")
    }

    @Test("A reset further out than the cadence does not delay the refresh")
    func distantResetDoesNotStretchTheDelay() {
        let delay = RefreshPolicy.nextDelay(for: input(resets: [now.addingTimeInterval(86_400)]))
        expectWithinJitter(delay, of: RefreshPolicy.idleInterval, "the cadence still applies")
    }

    @Test("Reset instants already in the past are ignored entirely")
    func pastResetsAreIgnored() {
        let stale = RefreshPolicy.nextDelay(
            for: input(
                resets: [
                    now.addingTimeInterval(-1),
                    now.addingTimeInterval(-86_400),
                    now,
                ]
            )
        )
        #expect(stale == RefreshPolicy.nextDelay(for: input()))
        expectWithinJitter(stale, of: RefreshPolicy.idleInterval, "a stale reset changes nothing")
    }

    @Test("Every delay is strictly positive")
    func everyDelayIsPositive() {
        let zeroRetry = UsageError(
            category: .rateLimited,
            reason: .httpStatus(code: 429),
            retry: UsageError.RetryAdvice(delay: .zero, scope: .account)
        )
        let inputs: [AccountRefreshInput] = [
            input(),
            input(outcome: .initial),
            input(outcome: .failure(zeroRetry), failures: 1),
            input(resets: [now.addingTimeInterval(0.001)]),
            input(resets: [now.addingTimeInterval(-5)]),
        ]
        for input in inputs {
            let delay = RefreshPolicy.nextDelay(for: input)
            #expect(delay >= RefreshPolicy.minimumDelay)
            #expect(delay > .zero)
        }
    }

    @Test("Jitter is deterministic, bounded, and different between accounts")
    func jitterIsBoundedAndPerAccount() {
        let ids = (0..<24).map { "account-\($0)" }
        var delays: Set<Duration> = []
        for id in ids {
            let delay = RefreshPolicy.nextDelay(for: input(id))
            #expect(delay == RefreshPolicy.nextDelay(for: input(id)), "jitter must not move")
            #expect(delay >= RefreshPolicy.idleInterval)
            #expect(delay <= RefreshPolicy.idleInterval + RefreshPolicy.maximumJitter)
            delays.insert(delay)
        }
        #expect(delays.count > 1, "accounts must not all wake in the same instant")
    }

    /// A reset 30s out shortens the delay to 60s, so jitter must shrink to 6s rather than staying
    /// at the 30s it is allowed on the five-minute cadence.
    @Test("Jitter of a short delay stays proportional rather than fixed")
    func jitterScalesWithTheDelay() {
        let soon = [now.adding(.seconds(30))]
        for id in (0..<24).map({ "account-\($0)" }) {
            let delay = RefreshPolicy.nextDelay(for: input(id, resets: soon))
            #expect(delay <= .seconds(60) + .seconds(6))
        }
    }
}
