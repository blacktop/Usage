import Foundation
import Synchronization

@testable import UsageKit

/// Observes how fetches overlap, and can hold them open until a given number are in flight.
///
/// Shared between providers, so a test can prove both that one provider stays inside its bound and
/// that two providers genuinely run at the same time.
actor FetchRecorder {
    private var inFlight: [ProviderID: Int] = [:]
    private var total = 0
    private var barrier: Int?
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private(set) var peakPerProvider: [ProviderID: Int] = [:]
    private(set) var peakTotal = 0
    private(set) var startOrder: [AccountKey] = []

    init(releaseWhenInFlight barrier: Int? = nil) {
        self.barrier = barrier
    }

    /// Marks a fetch as started and, when a barrier is set, waits for the rest of the group.
    func begin(_ key: AccountKey) async {
        let id = key.providerID
        let running = inFlight[id, default: 0] + 1
        inFlight[id] = running
        total += 1
        peakPerProvider[id] = max(peakPerProvider[id] ?? 0, running)
        peakTotal = max(peakTotal, total)
        startOrder.append(key)
        guard let barrier else { return }
        guard total < barrier else {
            let parked = waiting
            waiting = []
            for continuation in parked { continuation.resume() }
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func end(_ key: AccountKey) {
        inFlight[key.providerID] = (inFlight[key.providerID] ?? 1) - 1
        total -= 1
    }
}

/// Parks fetches so a test can act while a wave is genuinely in flight.
///
/// `FetchRecorder` answers "how did these overlap"; this answers "hold still while I do something
/// to the coordinator". A test can therefore suspend, refresh again, or rediscover at the one
/// moment those operations are interesting — with a fetch outstanding.
actor FetchGate {
    private var isOpen: Bool
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var observers: [CheckedContinuation<Void, Never>] = []

    private(set) var arrivals = 0

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    /// Called by the fetch itself. Returns immediately while the gate is open.
    func arrive() async {
        arrivals += 1
        let waiting = observers
        observers = []
        for observer in waiting { observer.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Waits until at least `count` fetches have reached the gate.
    func waitForArrival(count: Int = 1) async {
        while arrivals < count {
            await withCheckedContinuation { observers.append($0) }
        }
    }

    func close() {
        isOpen = false
    }

    func open() {
        isOpen = true
        let waiting = parked
        parked = []
        for continuation in waiting { continuation.resume() }
    }
}

/// A provider whose discovery and fetch results are scripted.
///
/// `providerID` is per instance rather than per type, so two stubs can stand in for two different
/// providers in one registry.
final class StubProvider: Provider, Sendable {
    static let id = ProviderID("stub")

    let providerID: ProviderID
    let displayName = "Stub"
    let dashboardURL = URL(filePath: "/dev/null")
    let maxConcurrentFetches: Int

    private struct Script {
        var accounts: [ProviderAccount]
        var discoveryFailure: UsageError?
        var queuedFailures: [AccountKey: [UsageError]] = [:]
        var resets: [AccountKey: Date] = [:]
        var fetchCounts: [AccountKey: Int] = [:]
        var misroutes: [AccountKey: AccountKey] = [:]
        var discoveryCount = 0
        var observedCancellation = false
    }

    /// What one scripted fetch decided, read out under the lock in a single step.
    private struct Outcome {
        let failure: UsageError?
        let reset: Date?
        let key: AccountKey
    }

    private let script: Mutex<Script>
    private let recorder: FetchRecorder?
    private let gate: FetchGate?

    init(
        providerID: ProviderID = StubProvider.id,
        accountIDs: [String],
        maxConcurrentFetches: Int = 1,
        recorder: FetchRecorder? = nil,
        gate: FetchGate? = nil
    ) {
        self.providerID = providerID
        self.maxConcurrentFetches = maxConcurrentFetches
        self.recorder = recorder
        self.gate = gate
        script = Mutex(Script(accounts: Self.accounts(accountIDs, provider: providerID)))
    }

    static func accounts(_ ids: [String], provider: ProviderID) -> [ProviderAccount] {
        ids.map { id in
            ProviderAccount(
                key: AccountKey(
                    providerID: provider,
                    accountID: .canonical(provider: provider, canonicalID: id)
                ),
                slot: CredentialSlotID(source: "stub", opaqueID: id),
                locator: CredentialLocator(kind: .file, identifier: "/dev/null"),
                displayName: "\(id)@example.com",
                availability: .active
            )
        }
    }

    func key(_ id: String) -> AccountKey {
        AccountKey(
            providerID: providerID,
            accountID: .canonical(provider: providerID, canonicalID: id)
        )
    }

    var accounts: [ProviderAccount] {
        script.withLock { $0.accounts }
    }

    func setAccounts(_ ids: [String]) {
        script.withLock { $0.accounts = Self.accounts(ids, provider: providerID) }
    }

    func failDiscovery(with error: UsageError?) {
        script.withLock { $0.discoveryFailure = error }
    }

    /// Queues failures for one account. Fetches beyond the queue succeed again.
    func fail(_ id: String, with error: UsageError, times: Int = 1) {
        let key = key(id)
        script.withLock {
            $0.queuedFailures[key, default: []]
                .append(contentsOf: Array(repeating: error, count: times))
        }
    }

    /// Gives one account's window a reset instant, which is what makes the policy wake for it.
    func setReset(_ id: String, at date: Date) {
        let key = key(id)
        script.withLock { $0.resets[key] = date }
    }

    /// Makes one account's fetch answer with a report keyed to a different account, which is what a
    /// provider that mis-maps a response looks like from the coordinator's side.
    func misroute(_ id: String, to other: String) {
        let (from, to) = (key(id), key(other))
        script.withLock { $0.misroutes[from] = to }
    }

    func fetchCount(_ id: String) -> Int {
        let key = key(id)
        return script.withLock { $0.fetchCounts[key] ?? 0 }
    }

    var discoveryCount: Int {
        script.withLock { $0.discoveryCount }
    }

    /// Whether any fetch ever saw its task cancelled, which is how a test proves the coordinator's
    /// own suspension did not reach a request already in flight.
    var observedCancellation: Bool {
        script.withLock { $0.observedCancellation }
    }

    func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        let script = script.withLock { script -> Script in
            script.discoveryCount += 1
            return script
        }
        if let failure = script.discoveryFailure { throw failure }
        return script.accounts
    }

    func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        await recorder?.begin(account.key)
        await gate?.arrive()
        await Task.yield()
        let outcome = script.withLock { script -> Outcome in
            script.fetchCounts[account.key, default: 0] += 1
            script.observedCancellation = script.observedCancellation || Task.isCancelled
            var queued = script.queuedFailures[account.key] ?? []
            let failure = queued.isEmpty ? nil : queued.removeFirst()
            script.queuedFailures[account.key] = queued
            return Outcome(
                failure: failure,
                reset: script.resets[account.key],
                key: script.misroutes[account.key] ?? account.key
            )
        }
        await Task.yield()
        await recorder?.end(account.key)
        if let failure = outcome.failure { throw failure }
        return try UsageReport(
            accountKey: outcome.key,
            plan: "stub",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: 0.5,
                    resetsAt: outcome.reset
                )
            ],
            capturedAt: context.clock.now
        )
    }
}
