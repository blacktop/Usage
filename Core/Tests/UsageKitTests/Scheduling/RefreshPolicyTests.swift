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
    @Test("Base cadence does not vary with anything outside the refresh input")
    func cadenceHasNoUnmeasuredInputs() {
        let quiet = RefreshPolicy.nextDelay(for: input("same-account"))
        let repeated = RefreshPolicy.nextDelay(for: input("same-account"))
        #expect(quiet == repeated, "the policy is pure, so equal inputs give equal delays")
        expectWithinJitter(quiet, of: RefreshPolicy.idleInterval, "one provider-facing cadence")
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

    @Test("A vanished credential retries on the short recovery cadence, not the provider one")
    func credentialFailureRecoversQuickly() {
        let missing = UsageError.credentialUnavailable(kind: .keychain)
        expectWithinJitter(
            RefreshPolicy.nextDelay(for: input(outcome: .failure(missing), failures: 1)),
            of: RefreshPolicy.credentialRecoveryInterval,
            "a rotated Keychain item is repaired by the rediscovery beside the retry"
        )
    }

    /// The recovery for this failure is the user's explicit approval, and a scheduled retry runs
    /// under the same no-UI policy that just refused the read. Putting it on the fast cadence
    /// would spend Keychain reads on an outcome that cannot change until the user acts.
    @Test("A credential awaiting approval keeps the ordinary cadence")
    func approvalFailureDoesNotRetryFast() {
        let locked = UsageError.interactionForbidden()
        expectWithinJitter(
            RefreshPolicy.nextDelay(for: input(outcome: .failure(locked), failures: 1)),
            of: RefreshPolicy.idleInterval,
            "only the user can clear an approval-gated read"
        )
    }

    @Test("Credential recovery still backs off exponentially and shares the ceiling")
    func credentialRecoveryStillBacksOff() {
        let failure = AccountRefreshInput.Outcome.failure(.credentialUnavailable(kind: .keychain))
        for count in 1...4 {
            expectWithinJitter(
                RefreshPolicy.nextDelay(for: input(outcome: failure, failures: count)),
                of: min(
                    RefreshPolicy.credentialRecoveryInterval * (1 << (count - 1)),
                    RefreshPolicy.backoffCeiling
                ),
                "credential failure \(count) doubles the short cadence"
            )
        }
        let capped = RefreshPolicy.nextDelay(for: input(outcome: failure, failures: 40))
        expectWithinJitter(capped, of: RefreshPolicy.backoffCeiling, "the ceiling is shared")
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

    @Test("A reset sooner than the floor cannot schedule a fetch inside five minutes")
    func futureResetNeverUndercutsTheFloor() {
        let delay = RefreshPolicy.nextDelay(
            for: input(
                resets: [
                    now.addingTimeInterval(3_600),
                    now.addingTimeInterval(120),
                    now.addingTimeInterval(600),
                ]
            )
        )
        expectWithinJitter(
            delay,
            of: RefreshPolicy.idleInterval,
            "the five-minute floor outranks a nearby reset"
        )
    }

    @Test("A reset wake pulls a failure-stretched backoff down to the floor, never below it")
    func futureResetShortensBackoffToTheFloor() {
        let failed = UsageError.from(HTTPResponse(status: 500))
        let backedOff = RefreshPolicy.nextDelay(
            for: input(outcome: .failure(failed), failures: 3)
        )
        #expect(
            backedOff >= RefreshPolicy.idleInterval * 4,
            "three failures back the cadence off to at least 20 minutes"
        )

        let pulled = RefreshPolicy.nextDelay(
            for: input(
                outcome: .failure(failed),
                failures: 3,
                resets: [now.addingTimeInterval(120)]
            )
        )
        expectWithinJitter(
            pulled,
            of: RefreshPolicy.idleInterval,
            "the reset wake shortens the backoff, and the floor catches it"
        )
    }

    @Test("Credential recovery stays exempt from the floor: it costs no provider request")
    func credentialRecoveryStaysBelowTheFloor() {
        let vanished = UsageError.credentialUnavailable(kind: .keychain)
        let delay = RefreshPolicy.nextDelay(
            for: input(outcome: .failure(vanished), failures: 1)
        )
        expectWithinJitter(
            delay,
            of: RefreshPolicy.credentialRecoveryInterval,
            "a local read retries on the 30-second recovery cadence"
        )
    }

    @Test(
        "A 429 without Retry-After backs off from the floor to the ceiling",
        arguments: [(1, 300), (2, 600), (3, 1_200), (4, 1_800), (9, 1_800)]
    )
    func rateLimitedBackoffWithoutRetryAfter(failures: Int, expectedSeconds: Int) {
        let rateLimited = UsageError.from(HTTPResponse(status: 429))
        #expect(rateLimited.retry == nil, "no Retry-After header means no advice")
        let delay = RefreshPolicy.nextDelay(
            for: input(outcome: .failure(rateLimited), failures: failures)
        )
        expectWithinJitter(
            delay,
            of: .seconds(expectedSeconds),
            "doubling from the five-minute floor, capped at 30 minutes"
        )
    }

    @Test("A zero Retry-After changes nothing about the schedule")
    func zeroRetryAfterIsInert() {
        let zero = UsageError.from(
            HTTPResponse(status: 429, headers: ["Retry-After": "0"])
        )
        #expect(zero.retry == UsageError.RetryAdvice(delay: .zero, scope: .account))
        let delay = RefreshPolicy.nextDelay(for: input(outcome: .failure(zero), failures: 1))
        expectWithinJitter(
            delay,
            of: RefreshPolicy.idleInterval,
            "zero advice neither shortens nor stretches the backoff"
        )
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

    /// Credential recovery is the one path still allowed under the five-minute floor, so its
    /// 30-second delay is where proportional jitter shows: 3s, not the 30s the idle cadence gets.
    @Test("Jitter of a short delay stays proportional rather than fixed")
    func jitterScalesWithTheDelay() {
        let vanished = UsageError.credentialUnavailable(kind: .keychain)
        for id in (0..<24).map({ "account-\($0)" }) {
            let delay = RefreshPolicy.nextDelay(
                for: input(id, outcome: .failure(vanished), failures: 1)
            )
            #expect(delay <= .seconds(30) + .seconds(3))
        }
    }
}
