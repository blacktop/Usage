import Foundation
import Testing

@testable import UsageKit

@Suite("Refresh coordinator")
struct RefreshCoordinatorTests {
    private static let rateLimit = Duration.seconds(900)

    private func rateLimited(scope: UsageError.RetryAdvice.Scope) -> UsageError {
        UsageError(
            category: .rateLimited,
            reason: .httpStatus(code: 429),
            retry: UsageError.RetryAdvice(delay: Self.rateLimit, scope: scope)
        )
    }

    private func coordinator(
        _ providers: [any Provider],
        clock: GatedClock,
        sink: EventLog,
        credentials: any CredentialSource = InMemoryCredentialSource(),
        stagger: Duration = .zero
    ) -> RefreshCoordinator {
        RefreshCoordinator(
            registry: ProviderRegistry(providers: providers),
            context: ProviderContext(
                http: InMemoryHTTPTransport(),
                credentials: credentials,
                fileSystem: InMemoryFileSystem(),
                clock: clock,
                interaction: BackgroundInteractionPolicy()
            ),
            sink: sink,
            configuration: RefreshCoordinator.Configuration(stagger: stagger)
        )
    }

    @Test("One account's failure neither cancels nor overwrites its siblings")
    func oneFailureLeavesSiblingsIntact() async throws {
        let provider = StubProvider(accountIDs: ["a", "b", "c"])
        provider.fail("b", with: .transportFailure())
        let log = EventLog()
        let coordinator = coordinator([provider], clock: GatedClock(), sink: log)

        await coordinator.refresh()

        #expect(await log.reports(for: provider.key("a")).count == 1)
        #expect(await log.reports(for: provider.key("c")).count == 1)
        #expect(await log.reports(for: provider.key("b")).isEmpty)
        #expect(await log.failures(for: provider.key("b")) == [.transportFailure()])
        #expect(await log.failures(for: provider.key("a")).isEmpty)
        #expect(await log.failures(for: provider.key("c")).isEmpty)
        for id in ["a", "b", "c"] {
            #expect(provider.fetchCount(id) == 1, "every sibling still ran exactly once")
        }
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 0)
        #expect(await coordinator.consecutiveFailures(for: provider.key("b")) == 1)
        #expect(await coordinator.consecutiveFailures(for: provider.key("c")) == 0)
        await coordinator.suspend()
    }

    @Test("Each success carries its own account's report")
    func reportsAreNotCrossedBetweenAccounts() async throws {
        let provider = StubProvider(accountIDs: ["a", "b"])
        let log = EventLog()
        let coordinator = coordinator([provider], clock: GatedClock(), sink: log)

        await coordinator.refresh()

        let first = try #require(await log.reports(for: provider.key("a")).first)
        let second = try #require(await log.reports(for: provider.key("b")).first)
        #expect(first.accountKey == provider.key("a"))
        #expect(second.accountKey == provider.key("b"))
        await coordinator.suspend()
    }

    @Test("credential approval performs the fetch inside the one authorized read")
    func credentialApprovalRetriesTheAccount() async throws {
        let provider = CredentialReadingProvider()
        let account = provider.account
        let backgroundCredentials = InMemoryCredentialSource(
            secrets: [account.locator: "FAKE-access-token-0000"],
            interactiveOnly: [account.locator]
        )
        let interactiveCredentials = InMemoryCredentialSource(
            secrets: [account.locator: "FAKE-access-token-0000"],
            interactiveOnly: [account.locator],
            interaction: UserInitiatedInteractionPolicy()
        )
        let log = EventLog()
        let coordinator = coordinator(
            [provider],
            clock: GatedClock(),
            sink: log,
            credentials: backgroundCredentials
        )
        await coordinator.refresh()

        await coordinator.approveCredentialAccess(
            for: account.key,
            using: interactiveCredentials
        )

        #expect(interactiveCredentials.resolvedLocators == [account.locator])
        #expect(
            backgroundCredentials.resolvedLocators == [account.locator],
            "approval must not issue a second background credential read"
        )
        #expect(provider.fetchCount == 2)
        #expect(await log.reports(for: account.key).count == 1)
        #expect(await log.failures(for: account.key) == [.interactionForbidden()])
        await coordinator.suspend()
    }

    @Test("a declined credential approval reports the authorization failure without succeeding")
    func declinedCredentialApprovalDoesNotFetch() async throws {
        let provider = CredentialReadingProvider()
        let account = provider.account
        let backgroundCredentials = InMemoryCredentialSource(
            secrets: [account.locator: "FAKE-access-token-0000"],
            interactiveOnly: [account.locator]
        )
        let log = EventLog()
        let coordinator = coordinator(
            [provider],
            clock: GatedClock(),
            sink: log,
            credentials: backgroundCredentials
        )
        await coordinator.refresh()

        await coordinator.approveCredentialAccess(for: account.key, using: backgroundCredentials)

        #expect(provider.fetchCount == 2)
        #expect(await log.reports(for: account.key).isEmpty)
        #expect(await log.failures(for: account.key).last == .interactionForbidden())
        await coordinator.suspend()
    }

    @Test("credential approval during suspension waits for wake before fetching")
    func credentialApprovalRespectsSuspension() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        let account = try #require(provider.accounts.first)
        let interactiveCredentials = InMemoryCredentialSource(
            secrets: [account.locator: "FAKE-access-token-0000"],
            interaction: UserInitiatedInteractionPolicy()
        )
        let log = EventLog()
        let coordinator = coordinator([provider], clock: GatedClock(), sink: log)
        await coordinator.refresh()
        await coordinator.suspend()

        await coordinator.approveCredentialAccess(
            for: account.key,
            using: interactiveCredentials
        )

        #expect(provider.fetchCount("a") == 1)
        #expect(interactiveCredentials.resolvedLocators.isEmpty)
        #expect(await log.events.last == .scheduled(key: account.key))
        #expect(!(await coordinator.hasScheduler))
    }

    @Test("An account-scoped 429 delays only that account")
    func accountScopedRateLimitIsNotContagious() async throws {
        let provider = StubProvider(accountIDs: ["a", "b"])
        provider.fail("b", with: rateLimited(scope: .account))
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()

        let start = clock.now
        let cooldown = try #require(await coordinator.cooldown(for: provider.key("b")))
        #expect(cooldown == start.adding(Self.rateLimit))
        #expect(await coordinator.cooldown(forProvider: provider.providerID) == nil)
        #expect(await coordinator.cooldown(for: provider.key("a")) == nil)

        let limited = try #require(await coordinator.deadline(for: provider.key("b")))
        let sibling = try #require(await coordinator.deadline(for: provider.key("a")))
        #expect(limited >= start.adding(Self.rateLimit))
        #expect(sibling < start.adding(Self.rateLimit))
        #expect(sibling >= start.adding(RefreshPolicy.idleInterval))
        await coordinator.suspend()
    }

    @Test("A provider-wide cooldown delays that provider's accounts and no others")
    func providerScopedRateLimitStopsOneProvider() async throws {
        let limited = StubProvider(providerID: ProviderID("p1"), accountIDs: ["a", "b"])
        let healthy = StubProvider(providerID: ProviderID("p2"), accountIDs: ["c"])
        limited.fail("a", with: rateLimited(scope: .provider))
        let clock = GatedClock()
        let coordinator = coordinator([limited, healthy], clock: clock, sink: EventLog())

        await coordinator.refresh()

        let start = clock.now
        let cooldown = try #require(await coordinator.cooldown(forProvider: limited.providerID))
        #expect(cooldown == start.adding(Self.rateLimit))
        #expect(await coordinator.cooldown(forProvider: healthy.providerID) == nil)
        #expect(await coordinator.cooldown(for: limited.key("a")) == nil, "the scope was provider")

        for id in ["a", "b"] {
            let deadline = try #require(await coordinator.deadline(for: limited.key(id)))
            #expect(deadline >= cooldown, "\(id) waits for the provider cooldown")
        }
        let unrelated = try #require(await coordinator.deadline(for: healthy.key("c")))
        #expect(unrelated < cooldown)

        clock.advance(by: RefreshPolicy.idleInterval + .seconds(1))
        await coordinator.refresh()
        #expect(limited.fetchCount("b") == 1, "a cooling provider is not refetched")
        #expect(healthy.fetchCount("c") == 2, "an unrelated provider still refreshes")
        await coordinator.suspend()
    }

    @Test("A hand on the refresh button cannot undercut the five-minute floor")
    func manualRefreshRespectsTheFloor() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a"])
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        #expect(provider.fetchCount("a") == 1, "the first fetch is free: nothing was attempted")

        await coordinator.refresh()
        await coordinator.refresh()
        #expect(
            provider.fetchCount("a") == 1,
            "repeated manual refreshes inside the floor send no request at all"
        )

        clock.advance(by: RefreshPolicy.idleInterval + .seconds(1))
        await coordinator.refresh()
        #expect(provider.fetchCount("a") == 2, "past the floor the manual refresh fetches again")
        await coordinator.suspend()
    }

    @Test("A manual refresh retries a request-free failure immediately")
    func manualRefreshRetriesLocalFailuresImmediately() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: .credentialUnavailable(kind: .keychain))
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        #expect(provider.fetchCount("a") == 1)

        await coordinator.refresh()

        #expect(
            provider.fetchCount("a") == 2,
            "a vanished-credential retry costs no provider request, so the floor does not apply"
        )
        await coordinator.suspend()
    }

    @Test("A manual refresh coalesces with the cooldown instead of bypassing it")
    func manualRefreshRespectsRetryAfter() async throws {
        let provider = StubProvider(accountIDs: ["a", "b"])
        provider.fail("b", with: rateLimited(scope: .account))
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        let cooldown = try #require(await coordinator.cooldown(for: provider.key("b")))

        clock.advance(by: RefreshPolicy.idleInterval + .seconds(1))
        await coordinator.refresh()

        #expect(provider.fetchCount("b") == 1, "the rate-limited account is still cooling")
        #expect(provider.fetchCount("a") == 2, "its sibling refreshes normally")
        #expect(await coordinator.cooldown(for: provider.key("b")) == cooldown)
        let deadline = try #require(await coordinator.deadline(for: provider.key("b")))
        #expect(deadline >= cooldown)
        await coordinator.suspend()
    }

    @Test("A success after a rate limit clears the cooldown it left behind")
    func successClearsTheCooldown() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: rateLimited(scope: .account))
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        #expect(await coordinator.cooldown(for: provider.key("a")) != nil)

        clock.advance(by: Self.rateLimit + .seconds(1))
        await coordinator.refresh()

        #expect(provider.fetchCount("a") == 2, "the cooldown had expired")
        #expect(await coordinator.cooldown(for: provider.key("a")) == nil)
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 0)
        await coordinator.suspend()
    }

    @Test("Consecutive failures accumulate and stretch the account's deadline")
    func failuresAccumulateAcrossWaves() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: .transportFailure(), times: 3)
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        let first = try #require(await coordinator.deadline(for: provider.key("a")))
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 1)

        clock.advance(by: RefreshPolicy.idleInterval + .seconds(1))
        await coordinator.refresh()

        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 2)
        let second = try #require(await coordinator.deadline(for: provider.key("a")))
        #expect(second > first, "the second failure backs further off than the first")
        #expect(second >= clock.now.adding(RefreshPolicy.idleInterval * 2))
        await coordinator.suspend()
    }

    @Test("Sleep and wake preserve failure counts and cooldowns")
    func wakeDoesNotResetBackoff() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: rateLimited(scope: .account), times: 2)
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        let cooldown = try #require(await coordinator.cooldown(for: provider.key("a")))
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 1)

        await coordinator.suspend()
        #expect(await coordinator.hasScheduler == false)

        await coordinator.refresh()

        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 1)
        #expect(await coordinator.cooldown(for: provider.key("a")) == cooldown)
        #expect(provider.fetchCount("a") == 1, "the wake refresh honoured the cooldown")
        #expect(await coordinator.hasScheduler, "the scheduler restarts on wake")
        await coordinator.suspend()
    }

    @Test("The earliest deadline drives exactly one timer")
    func oneTimerServesEveryAccount() async throws {
        let provider = StubProvider(accountIDs: ["a", "b", "c"])
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()

        // Three accounts, three jittered deadlines, one timer: each wake serves the account whose
        // deadline is currently the minimum and then re-times itself.
        for _ in 0..<3 {
            let requested = await clock.nextSleep()
            #expect(clock.sleepingCount == 1, "one scheduler task, one outstanding wait")
            let earliest = try #require(await coordinator.earliestDeadline)
            #expect(abs(requested.totalSeconds - earliest.timeIntervalSince(clock.now)) < 0.001)
            clock.fireOldestSleep()
        }
        _ = await clock.nextSleep()

        #expect(clock.sleepingCount == 1)
        for id in ["a", "b", "c"] {
            #expect(provider.fetchCount(id) == 2, "every account was served by the one timer")
        }
        await coordinator.suspend()
    }

    @Test("A near reset cannot schedule a fetch inside the five-minute floor")
    func futureResetRespectsTheFloor() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a"])
        provider.setReset("a", at: clock.now.addingTimeInterval(90))
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()

        let requested = await clock.nextSleep()
        #expect(
            requested >= RefreshPolicy.idleInterval,
            "the floor outranks the reset wake: no request sooner than five minutes"
        )
        await coordinator.suspend()
    }

    @Test(
        "No provider exceeds its declared concurrency bound",
        .timeLimit(.minutes(1))
    )
    func concurrencyBoundsAreRespected() async throws {
        let serial = FetchRecorder()
        let parallel = FetchRecorder(releaseWhenInFlight: 2)
        let one = StubProvider(
            providerID: ProviderID("p1"),
            accountIDs: ["a", "b", "c"],
            maxConcurrentFetches: 1,
            recorder: serial
        )
        let two = StubProvider(
            providerID: ProviderID("p2"),
            accountIDs: ["d", "e"],
            maxConcurrentFetches: 2,
            recorder: parallel
        )
        let coordinator = coordinator([one, two], clock: GatedClock(), sink: EventLog())

        await coordinator.refresh()

        #expect(await serial.peakPerProvider[one.providerID] == 1)
        #expect(await parallel.peakPerProvider[two.providerID] == 2)
        #expect(await serial.startOrder.count == 3)
        await coordinator.suspend()
    }

    @Test("Different providers refresh at the same time", .timeLimit(.minutes(1)))
    func providersOverlap() async throws {
        let recorder = FetchRecorder(releaseWhenInFlight: 2)
        let one = StubProvider(providerID: ProviderID("p1"), accountIDs: ["a"], recorder: recorder)
        let two = StubProvider(providerID: ProviderID("p2"), accountIDs: ["b"], recorder: recorder)
        let coordinator = coordinator([one, two], clock: GatedClock(), sink: EventLog())

        await coordinator.refresh()

        #expect(await recorder.peakTotal == 2, "the two providers were in flight together")
        await coordinator.suspend()
    }

    @Test("One provider's accounts are staggered rather than started together")
    func fetchesAreStaggeredWithinAProvider() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a", "b", "c"])
        let coordinator = coordinator(
            [provider],
            clock: clock,
            sink: EventLog(),
            stagger: .seconds(2)
        )

        let driver = Task {
            for _ in 0..<2 {
                _ = await clock.nextSleep()
                clock.fireOldestSleep()
            }
        }
        await coordinator.refresh()
        await driver.value

        #expect(clock.recordedSleeps.filter { $0 == .seconds(2) }.count == 2)
        for id in ["a", "b", "c"] {
            #expect(provider.fetchCount(id) == 1)
        }
        await coordinator.suspend()
    }

    @Test("A discovery failure keeps the accounts already known")
    func discoveryFailureKeepsExistingSchedule() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        let log = EventLog()
        let clock = GatedClock()
        let coordinator = coordinator([provider], clock: clock, sink: log)

        await coordinator.refresh()
        let deadline = try #require(await coordinator.deadline(for: provider.key("a")))

        provider.failDiscovery(with: .credentialUnavailable(kind: .file))
        clock.advance(by: RefreshPolicy.idleInterval + .seconds(1))
        await coordinator.refresh()

        #expect(await log.discoveryFailures(for: provider.providerID).count == 1)
        #expect(await coordinator.deadline(for: provider.key("a")) != nil)
        #expect(deadline < clock.now.adding(RefreshPolicy.backoffCeiling))
        #expect(
            provider.fetchCount("a") == 2, "a known account still refreshes from its descriptor")
        await coordinator.suspend()
    }

    @Test("An account that disappears takes its schedule with it")
    func removedAccountsLoseTheirSchedule() async throws {
        let provider = StubProvider(accountIDs: ["a", "b"])
        let coordinator = coordinator([provider], clock: GatedClock(), sink: EventLog())

        await coordinator.refresh()
        #expect(await coordinator.deadline(for: provider.key("b")) != nil)

        provider.setAccounts(["a"])
        await coordinator.refresh()

        #expect(await coordinator.deadline(for: provider.key("b")) == nil)
        #expect(await coordinator.deadline(for: provider.key("a")) != nil)
        #expect(provider.fetchCount("b") == 1)
        await coordinator.suspend()
    }

    @Test(
        "A manual refresh during a fetch coalesces instead of starting a second one",
        .timeLimit(.minutes(1))
    )
    func manualRefreshCoalescesWithAnInFlightFetch() async throws {
        let gate = FetchGate()
        let log = EventLog()
        let provider = StubProvider(accountIDs: ["a"], gate: gate)
        let coordinator = coordinator([provider], clock: GatedClock(), sink: log)

        let scheduled = Task { await coordinator.refresh() }
        await gate.waitForArrival()
        let manual = Task { await coordinator.refresh() }
        while await coordinator.pendingWaves < 2 { await Task.yield() }
        await gate.open()
        await scheduled.value
        await manual.value

        #expect(provider.fetchCount("a") == 1, "the manual refresh joined the fetch in flight")
        #expect(await log.beganCount(for: provider.key("a")) == 1)
        await coordinator.suspend()
    }

    @Test(
        "Two waves cannot exceed a provider's concurrency bound between them",
        .timeLimit(.minutes(1))
    )
    func overlappingWavesRespectTheProviderBound() async throws {
        let recorder = FetchRecorder()
        let gate = FetchGate()
        let provider = StubProvider(
            accountIDs: ["a"],
            maxConcurrentFetches: 1,
            recorder: recorder,
            gate: gate
        )
        let coordinator = coordinator([provider], clock: GatedClock(), sink: EventLog())

        let scheduled = Task { await coordinator.refresh() }
        await gate.waitForArrival()
        // A second account appears while the first one's request is still open. Its wave must wait
        // for the bound, not run beside the wave that is holding it.
        provider.setAccounts(["a", "b"])
        let manual = Task { await coordinator.refresh() }
        while await coordinator.pendingWaves < 2 { await Task.yield() }
        await gate.open()
        await scheduled.value
        await manual.value

        #expect(await recorder.peakPerProvider[provider.providerID] == 1)
        #expect(provider.fetchCount("b") == 1, "the new account was still fetched, just later")
        await coordinator.suspend()
    }

    @Test("Suspending during a wave leaves no scheduler behind", .timeLimit(.minutes(1)))
    func suspendDuringAWaveLeavesNoScheduler() async throws {
        let gate = FetchGate()
        let provider = StubProvider(accountIDs: ["a"], gate: gate)
        let coordinator = coordinator([provider], clock: GatedClock(), sink: EventLog())

        let refresh = Task { await coordinator.refresh() }
        await gate.waitForArrival()
        await coordinator.suspend()
        #expect(await coordinator.hasScheduler == false)
        await gate.open()
        await refresh.value

        #expect(
            await coordinator.hasScheduler == false,
            "a wave that finishes after willSleep must not re-arm the timer"
        )
    }

    @Test("Suspending never cancels a fetch already in flight", .timeLimit(.minutes(1)))
    func suspendDoesNotCancelAnInFlightFetch() async throws {
        let gate = FetchGate(isOpen: true)
        let clock = GatedClock()
        let log = EventLog()
        let provider = StubProvider(accountIDs: ["a"], gate: gate)
        let coordinator = coordinator([provider], clock: clock, sink: log)

        await coordinator.refresh()
        await gate.close()

        // The second wave is the scheduler's own, so suspending has to cancel the timer without
        // reaching the request the timer started.
        _ = await clock.nextSleep()
        clock.fireOldestSleep()
        await gate.waitForArrival(count: 2)
        await coordinator.suspend()
        await gate.open()
        while await coordinator.pendingWaves > 0 { await Task.yield() }

        #expect(provider.observedCancellation == false)
        #expect(await log.reports(for: provider.key("a")).count == 2)
        #expect(await log.failures(for: provider.key("a")).isEmpty)
    }

    @Test("An empty discovery keeps the schedule of the accounts it did not mention")
    func emptyDiscoveryKeepsExistingState() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: rateLimited(scope: .account))
        let coordinator = coordinator([provider], clock: GatedClock(), sink: EventLog())

        await coordinator.refresh()
        let cooldown = try #require(await coordinator.cooldown(for: provider.key("a")))

        provider.setAccounts([])
        await coordinator.refresh()

        #expect(
            await coordinator.cooldown(for: provider.key("a")) == cooldown,
            "an unreadable credential store is not an account removal"
        )
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 1)
        #expect(await coordinator.deadline(for: provider.key("a")) != nil)
        #expect(provider.fetchCount("a") == 1, "the cooling account was not refetched")
        await coordinator.suspend()
    }

    @Test(
        "An empty account set still schedules the rediscovery that finds the first account",
        .timeLimit(.minutes(1))
    )
    func emptyAccountSetStillRediscovers() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: [])
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        try #require(await coordinator.hasScheduler)

        let requested = await clock.nextSleep()
        #expect(requested == RefreshCoordinator.Configuration().discoveryInterval)

        provider.setAccounts(["a"])
        clock.fireOldestSleep()
        while provider.fetchCount("a") == 0 { await Task.yield() }

        #expect(provider.discoveryCount == 2, "the scheduled wave rediscovered")
        await coordinator.suspend()
    }

    @Test(
        "A vanished credential forces rediscovery on its retry wave",
        .timeLimit(.minutes(1))
    )
    func credentialFailureForcesRediscovery() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: .credentialUnavailable(kind: .keychain))
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        #expect(provider.discoveryCount == 1)

        _ = await clock.nextSleep()
        clock.fireOldestSleep()
        while provider.fetchCount("a") < 2 { await Task.yield() }

        #expect(
            provider.discoveryCount == 2,
            "the retry re-resolved the stale locator before fetching"
        )
        await coordinator.suspend()
    }

    @Test(
        "An expired authentication forces rediscovery on its retry wave",
        .timeLimit(.minutes(1))
    )
    func authenticationFailureForcesRediscovery() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: UsageError.from(HTTPResponse(status: 401)))
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        #expect(provider.discoveryCount == 1)

        _ = await clock.nextSleep()
        clock.fireOldestSleep()
        while provider.fetchCount("a") < 2 { await Task.yield() }

        #expect(
            provider.discoveryCount == 2,
            "a 401 means the token rotated or a new source appeared; the retry re-resolves first"
        )
        await coordinator.suspend()
    }

    @Test(
        "A provider failure keeps the coarse discovery interval",
        .timeLimit(.minutes(1))
    )
    func providerFailureDoesNotForceRediscovery() async throws {
        let clock = GatedClock()
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: .transportFailure())
        let coordinator = coordinator([provider], clock: clock, sink: EventLog())

        await coordinator.refresh()
        #expect(provider.discoveryCount == 1)

        _ = await clock.nextSleep()
        clock.fireOldestSleep()
        while provider.fetchCount("a") < 2 { await Task.yield() }

        #expect(
            provider.discoveryCount == 1,
            "a network failure says nothing about the credential store"
        )
        await coordinator.suspend()
    }

    @Test("A report keyed to another account is refused rather than written to it")
    func crossAccountReportsAreRefused() async throws {
        let provider = StubProvider(accountIDs: ["a", "b"])
        provider.misroute("a", to: "b")
        let log = EventLog()
        let coordinator = coordinator([provider], clock: GatedClock(), sink: log)

        await coordinator.refresh()

        #expect(
            await log.failures(for: provider.key("a")) == [
                UsageError.invalidValue(field: "accountKey", rule: .consistent)
            ]
        )
        #expect(await log.reports(for: provider.key("a")).isEmpty)
        #expect(
            await log.reports(for: provider.key("b")).count == 1,
            "the other account keeps exactly its own report"
        )
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 1)
        #expect(await coordinator.consecutiveFailures(for: provider.key("b")) == 0)
        await coordinator.suspend()
    }

    @Test("A cancelled fetch is not counted as the provider's failure")
    func cancelledFetchIsNotAFailure() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: .cancelled())
        let log = EventLog()
        let coordinator = coordinator([provider], clock: GatedClock(), sink: log)

        await coordinator.refresh()
        await coordinator.suspend()

        #expect(
            await log.failures(for: provider.key("a")).isEmpty,
            "our own cancellation is not an error the user has to see"
        )
        #expect(await coordinator.consecutiveFailures(for: provider.key("a")) == 0)
        #expect(await coordinator.cooldown(for: provider.key("a")) == nil)
    }

    @Test("A cooling account keeps its deadline behind the cooldown")
    func aCooldownIsNeverBypassed() async throws {
        let provider = StubProvider(accountIDs: ["a"])
        provider.fail("a", with: rateLimited(scope: .account))
        let coordinator = coordinator([provider], clock: GatedClock(), sink: EventLog())

        await coordinator.refresh()
        let cooldown = try #require(await coordinator.cooldown(for: provider.key("a")))

        await coordinator.refresh()

        let deadline = try #require(await coordinator.deadline(for: provider.key("a")))
        #expect(deadline >= cooldown, "a manual refresh must not pull a deadline inside a cooldown")
        await coordinator.suspend()
    }
}
