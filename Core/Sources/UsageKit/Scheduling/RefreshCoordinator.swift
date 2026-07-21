import Foundation

/// Owns every account's refresh schedule and runs the fetches.
///
/// One cancellable scheduler task sleeps until the earliest deadline, refreshes only the accounts
/// that are due, and recomputes the minimum. Fetches run in non-throwing task groups, so one
/// account's failure can neither cancel nor overwrite a sibling's result. Nothing here holds a
/// credential: a `ProviderAccount` is secret-free by construction and every credential is resolved
/// and dropped inside one provider operation.
public actor RefreshCoordinator {
    public struct Configuration: Sendable {
        /// Gap inserted between one provider's fetches inside a single wave, so a provider with
        /// many accounts cannot emit a request storm on launch, on wake, or after a long sleep.
        public var stagger: Duration

        /// How coarsely a wave re-runs account discovery. Deliberately far slower than the refresh
        /// cadence: an agent being signed in to is a rare event, and it must not cost a credential
        /// read every five minutes.
        public var discoveryInterval: Duration

        public init(stagger: Duration = .seconds(2), discoveryInterval: Duration = .seconds(900)) {
            self.stagger = stagger
            self.discoveryInterval = discoveryInterval
        }
    }

    private struct ScheduleState {
        var account: ProviderAccount
        /// The instant this account's deadline is measured from: its last completed attempt, or
        /// its discovery before any attempt completed.
        var anchoredAt: Date
        var outcome: AccountRefreshInput.Outcome = .initial
        var consecutiveFailures = 0
        var resetDates: [Date] = []
        /// An account-scoped `Retry-After` cooldown. Survives sleep, wake, and manual refresh.
        var cooldownUntil: Date?
        var dueAt: Date
        var isInFlight = false
    }

    private enum FetchResult: Sendable {
        case success(AccountKey, UsageReport)
        case failure(AccountKey, UsageError)

        var key: AccountKey {
            switch self {
            case .success(let key, _): key
            case .failure(let key, _): key
            }
        }
    }

    private let registry: ProviderRegistry
    private let context: ProviderContext
    private let sink: any RefreshEventSink
    private let configuration: Configuration

    private var states: [AccountKey: ScheduleState] = [:]
    private var order: [AccountKey] = []
    /// Cooldowns a provider contract classified as provider-wide. Absent that evidence a
    /// `Retry-After` lands on one account only.
    private var providerCooldowns: [ProviderID: Date] = [:]
    private var schedulerTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var schedulerGeneration = 0
    /// Set by `suspend()` and cleared by `refresh()`. Without it a wave that is still finishing
    /// when the machine goes to sleep re-arms the timer from its own `defer`.
    private var isSuspended = false
    /// The instant the next wave re-runs discovery.
    private var nextDiscoveryAt = Date.distantPast
    /// The most recently queued wave. Waves chain onto it rather than running beside it.
    private var waveTask: Task<Void, Never>?
    private var pendingWaveCount = 0

    public init(
        registry: ProviderRegistry,
        context: ProviderContext,
        sink: any RefreshEventSink,
        configuration: Configuration = Configuration()
    ) {
        self.registry = registry
        self.context = context
        self.sink = sink
        self.configuration = configuration
    }

    private var clock: any UsageClock { context.clock }
}

// MARK: - Entry points

extension RefreshCoordinator {
    /// Rediscovers accounts, refreshes every account that is not already in flight, and starts the
    /// scheduler. Launch, wake, and a user's manual refresh all land here.
    ///
    /// Coalesces rather than duplicates: an account with a fetch in flight is left alone. Cooldowns
    /// and failure counts are never cleared, so neither a manual refresh nor a wake can walk past a
    /// `Retry-After` the provider asked for.
    public func refresh() async {
        isSuspended = false
        await discover()
        markDue(at: clock.now)
        await runWave()
        ensureScheduler()
    }

    /// Stops the scheduler without discarding schedule state.
    ///
    /// In-flight fetches are left to finish or fail on their own: cancelling them would throw away
    /// a request already paid for, and the cancellation would land on the account as a failure the
    /// provider never caused. That holds because a wave runs in an unstructured task the scheduler
    /// only awaits, so cancelling the timer cannot reach a request inside it.
    ///
    /// Suspension is sticky until the next `refresh()`. A wave that is still finishing must not
    /// re-arm the timer the machine has just been told to stop using.
    public func suspend() {
        isSuspended = true
        sleepTask?.cancel()
        sleepTask = nil
        schedulerTask?.cancel()
        schedulerTask = nil
    }

    /// The next deadline the scheduler will wake for, ignoring accounts already in flight.
    public var earliestDeadline: Date? {
        states.values.filter { !$0.isInFlight }.map(\.dueAt).min()
    }

    public func deadline(for key: AccountKey) -> Date? {
        states[key]?.dueAt
    }

    public func cooldown(for key: AccountKey) -> Date? {
        states[key]?.cooldownUntil
    }

    public func cooldown(forProvider id: ProviderID) -> Date? {
        providerCooldowns[id]
    }

    public func consecutiveFailures(for key: AccountKey) -> Int {
        states[key]?.consecutiveFailures ?? 0
    }

    /// Whether the one scheduler task is currently alive. It is absent only while suspended.
    public var hasScheduler: Bool {
        schedulerTask != nil
    }

    /// Waves running or queued behind the one in flight. A second wave that starts no second fetch
    /// is how a manual refresh proves it coalesced with work already in flight.
    var pendingWaves: Int {
        pendingWaveCount
    }
}

// MARK: - Discovery

extension RefreshCoordinator {
    private func discover() async {
        nextDiscoveryAt = clock.now.adding(configuration.discoveryInterval)
        let context = context
        await withTaskGroup(of: DiscoveryResult.self) { group in
            for provider in registry.providers {
                group.addTask { await Self.discover(from: provider, using: context) }
            }
            for await result in group {
                await install(result)
            }
        }
    }

    private struct DiscoveryResult: Sendable {
        let providerID: ProviderID
        let accounts: [ProviderAccount]?
        let error: UsageError?
    }

    private nonisolated static func discover(
        from provider: any Provider,
        using context: ProviderContext
    ) async -> DiscoveryResult {
        do {
            let accounts = try await provider.discoverAccounts(using: context)
            return DiscoveryResult(providerID: provider.providerID, accounts: accounts, error: nil)
        } catch {
            return DiscoveryResult(
                providerID: provider.providerID,
                accounts: nil,
                error: UsageError.normalized(error)
            )
        }
    }

    private func install(_ result: DiscoveryResult) async {
        guard let accounts = result.accounts else {
            let error = result.error ?? .providerUnavailable()
            await sink.receive(.discoveryFailed(error: error, provider: result.providerID))
            return
        }
        let now = clock.now
        install(accounts, for: result.providerID, at: now)
        await sink.receive(
            .discovered(accounts: accounts, provider: result.providerID, at: now)
        )
    }

    /// Replaces one provider's rows. A row that survives keeps its cooldown, failure count, and
    /// deadline; a row that disappears takes its schedule with it.
    ///
    /// An empty result removes nothing. Every provider answers with an empty array both for "this
    /// account is gone" and for "the credential store could not be read this instant" — a locked
    /// Keychain, a credential file caught mid-rewrite — and deleting the row would silently drop
    /// the `Retry-After` cooldown and the backoff the provider asked for.
    private func install(_ accounts: [ProviderAccount], for id: ProviderID, at now: Date) {
        guard !accounts.isEmpty else { return }
        let surviving = Set(accounts.map(\.key))
        let retired = Set(
            order.filter {
                $0.providerID == id && !surviving.contains($0) && states[$0]?.isInFlight != true
            }
        )
        for key in retired {
            states[key] = nil
        }
        order.removeAll(where: retired.contains)
        for account in accounts {
            guard var existing = states[account.key] else {
                states[account.key] = ScheduleState(account: account, anchoredAt: now, dueAt: now)
                order.append(account.key)
                continue
            }
            existing.account = account
            states[account.key] = existing
        }
    }
}

// MARK: - Waves

extension RefreshCoordinator {
    /// Marks every idle account due now. A cooldown is not consulted here and does not need to be:
    /// `claimIfDue` is the one place a fetch can start, and it refuses a cooling account there.
    private func markDue(at now: Date) {
        for key in order {
            guard var state = states[key], !state.isInFlight else { continue }
            state.dueAt = now
            states[key] = state
        }
    }

    /// Queues a wave behind whatever is already running and waits for it.
    ///
    /// Waves are serialized and unstructured on purpose. Serialized, because a provider's
    /// `maxConcurrentFetches` bound is a property of the provider and not of one wave: two
    /// overlapping waves would otherwise each start `bound` fetches. Unstructured, because the
    /// scheduler awaits this — cancelling the timer must not reach a request inside it.
    private func runWave() async {
        pendingWaveCount += 1
        let previous = waveTask
        let task = Task { [weak self] in
            await previous?.value
            await self?.performWave()
        }
        waveTask = task
        await task.value
        pendingWaveCount -= 1
        if waveTask == task { waveTask = nil }
    }

    /// Fetches every due account, grouped by provider so different providers overlap while one
    /// provider's accounts stay inside its declared bound.
    private func performWave() async {
        // The scheduler is (re)started once, after every deadline this wave touches is final, so
        // the one timer always sleeps until the true minimum rather than an intermediate one.
        defer { ensureScheduler() }
        if clock.now >= nextDiscoveryAt {
            await discover()
        }
        let now = clock.now
        var work: [ProviderID: [ProviderAccount]] = [:]
        for key in order {
            guard let account = claimIfDue(key, at: now) else { continue }
            work[key.providerID, default: []].append(account)
        }
        guard !work.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for provider in registry.providers {
                guard let accounts = work[provider.providerID], !accounts.isEmpty else { continue }
                group.addTask { await self.run(accounts, on: provider) }
            }
        }
    }

    /// Takes an account for this wave, or pushes its deadline out to its cooldown and declines it.
    private func claimIfDue(_ key: AccountKey, at now: Date) -> ProviderAccount? {
        guard var state = states[key], !state.isInFlight else { return nil }
        let earliest = clamped(state.dueAt, for: key, state: state)
        guard earliest <= now else {
            state.dueAt = earliest
            states[key] = state
            return nil
        }
        state.isInFlight = true
        states[key] = state
        return state.account
    }

    /// Runs one provider's due accounts, at most `maxConcurrentFetches` at a time, with a stagger
    /// between starts so a provider that permits several never starts them in the same instant.
    private func run(_ accounts: [ProviderAccount], on provider: any Provider) async {
        let bound = max(1, provider.maxConcurrentFetches)
        let context = context
        await withTaskGroup(of: FetchResult.self) { group in
            var pending = accounts[...]
            var running = 0
            var started = 0
            while !pending.isEmpty || running > 0 {
                while running < bound, let account = pending.popFirst() {
                    if started > 0, configuration.stagger > .zero {
                        try? await clock.sleep(for: configuration.stagger)
                    }
                    started += 1
                    running += 1
                    await sink.receive(.began(key: account.key, at: clock.now))
                    group.addTask { await Self.fetch(account, from: provider, using: context) }
                }
                guard let result = await group.next() else { break }
                running -= 1
                await complete(result)
            }
        }
    }

    private nonisolated static func fetch(
        _ account: ProviderAccount,
        from provider: any Provider,
        using context: ProviderContext
    ) async -> FetchResult {
        do {
            let report = try await provider.fetchUsage(for: account, using: context)
            guard report.accountKey == account.key else {
                return .failure(
                    account.key,
                    UsageError.invalidValue(field: "accountKey", rule: .consistent)
                )
            }
            return .success(account.key, report)
        } catch {
            return .failure(account.key, UsageError.normalized(error))
        }
    }

    /// Records one fetch's outcome, then tells the outside world.
    ///
    /// Every mutation happens before the first `await`. Clearing the in-flight mark first would
    /// publish an account that is idle but still carries the deadline it was fetched under, and the
    /// hop into the sink is long enough for another wave to claim it and fetch it again.
    private func complete(_ result: FetchResult) async {
        let now = clock.now
        guard states[result.key] != nil else { return }
        switch result {
        case .success(let key, let report):
            recordSuccess(report, for: key, at: now)
        case .failure(_, let error) where error.category == .cancelled:
            // Our own suspension, not the provider's failure: it must not move the account's
            // backoff, its cooldown, or the last report the user is looking at.
            break
        case .failure(let key, let error):
            recordFailure(error, for: key, at: now)
        }
        settle(result.key, now: now)
        await emit(result, at: now)
    }

    /// Clears the in-flight mark and installs the next deadline in one synchronous step.
    private func settle(_ key: AccountKey, now: Date) {
        guard var state = states[key] else { return }
        state.isInFlight = false
        states[key] = state
        recomputeDeadline(key, now: now)
    }

    private func emit(_ result: FetchResult, at now: Date) async {
        switch result {
        case .success(_, let report):
            await sink.receive(.succeeded(report: report, at: now))
        case .failure(_, let error) where error.category == .cancelled:
            break
        case .failure(let key, let error):
            await sink.receive(.failed(error: error, key: key, at: now))
        }
        await sink.receive(.scheduled(key: result.key))
    }

    private func recordSuccess(_ report: UsageReport, for key: AccountKey, at now: Date) {
        guard var state = states[key] else { return }
        state.anchoredAt = now
        state.outcome = .success
        state.consecutiveFailures = 0
        state.resetDates = report.windows.compactMap(\.resetsAt)
        state.cooldownUntil = nil
        states[key] = state
    }

    private func recordFailure(_ error: UsageError, for key: AccountKey, at now: Date) {
        guard var state = states[key] else { return }
        state.anchoredAt = now
        state.outcome = .failure(error)
        state.consecutiveFailures += 1
        if let retry = error.retry {
            switch retry.scope {
            case .account:
                state.cooldownUntil = now.adding(retry.delay)
            case .provider:
                providerCooldowns[key.providerID] = now.adding(retry.delay)
                clampDeadlines(ofProvider: key.providerID)
            }
        }
        states[key] = state
    }

    /// Pushes every account of one provider out to a freshly installed provider-wide cooldown.
    /// Accounts still in flight are clamped when they complete.
    private func clampDeadlines(ofProvider id: ProviderID) {
        for key in order where key.providerID == id {
            guard var state = states[key], !state.isInFlight else { continue }
            state.dueAt = clamped(state.dueAt, for: key, state: state)
            states[key] = state
        }
    }
}

// MARK: - Deadlines

extension RefreshCoordinator {
    /// Re-derives one account's deadline from the policy. Idempotent: the delay is measured from
    /// the account's anchor, not from the moment this happens to run.
    private func recomputeDeadline(_ key: AccountKey, now: Date) {
        guard var state = states[key], !state.isInFlight else { return }
        guard state.outcome != .initial else {
            state.dueAt = clamped(state.dueAt, for: key, state: state)
            states[key] = state
            return
        }
        let delay = RefreshPolicy.nextDelay(
            for: AccountRefreshInput(
                key: key,
                now: state.anchoredAt,
                outcome: state.outcome,
                consecutiveFailures: state.consecutiveFailures,
                resetDates: state.resetDates
            )
        )
        state.dueAt = clamped(state.anchoredAt.adding(delay), for: key, state: state)
        states[key] = state
    }

    /// A deadline no earlier than every cooldown that applies to this account.
    private func clamped(_ date: Date, for key: AccountKey, state: ScheduleState) -> Date {
        var result = date
        if let until = state.cooldownUntil {
            result = max(result, until)
        }
        if let until = providerCooldowns[key.providerID] {
            result = max(result, until)
        }
        return result
    }
}

// MARK: - Scheduler

extension RefreshCoordinator {
    /// Starts the one scheduler task if it is not already running.
    private func ensureScheduler() {
        guard !isSuspended, schedulerTask == nil else { return }
        schedulerGeneration += 1
        let generation = schedulerGeneration
        schedulerTask = Task { [weak self] in
            await self?.runScheduler(generation: generation)
        }
    }

    /// The instant the one timer waits for.
    ///
    /// Falls back to the next discovery when no account is known, so a machine that had not been
    /// signed in to when Usage launched still gets a wave that rediscovers, rather than leaving the
    /// coordinator dormant until the user refreshes by hand.
    private var schedulerDeadline: Date {
        earliestDeadline ?? nextDiscoveryAt
    }

    private func runScheduler(generation: Int) async {
        while !Task.isCancelled {
            await sleep(until: schedulerDeadline)
            guard !Task.isCancelled else { break }
            await runWave()
        }
        if generation == schedulerGeneration {
            schedulerTask = nil
        }
    }

    /// Sleeps in a child task so a deadline that moves earlier can interrupt the wait without
    /// cancelling the scheduler — or, worse, a fetch that is already in flight.
    private func sleep(until deadline: Date) async {
        let seconds = deadline.timeIntervalSince(clock.now)
        guard seconds > 0 else { return }
        let clock = clock
        let task = Task {
            // A cancelled wait is this scheduler's own interruption signal, not a failure.
            _ = try? await clock.sleep(for: .seconds(seconds))
        }
        sleepTask = task
        await task.value
        sleepTask = nil
    }
}
