import Foundation
import Synchronization

/// `UsageClock` whose sleeps park until a test releases them.
///
/// `ManualClock` answers "what delay was asked for"; this answers "what is the code doing while it
/// waits". A scheduler under test therefore stays parked instead of spinning through instant
/// sleeps, and a test can prove that exactly one wait is outstanding without touching the wall
/// clock or asserting on elapsed time.
public final class GatedClock: UsageClock, Sendable {
    private struct Waiter {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now: Date
        var nextID = 0
        var waiters: [Waiter] = []
        var cancelled: Set<Int> = []
        /// Requested durations no `nextSleep()` has consumed yet.
        var unobserved: [Duration] = []
        var observers: [CheckedContinuation<Duration, Never>] = []
        var recorded: [Duration] = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    /// Sleeps that have been requested and not yet released or cancelled.
    public var sleepingCount: Int {
        state.withLock { $0.waiters.count }
    }

    /// Every duration ever passed to `sleep(for:)`, in call order.
    public var recordedSleeps: [Duration] {
        state.withLock { $0.recorded }
    }

    /// Moves time forward without releasing anything that is waiting.
    public func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.adding(duration) }
    }

    /// Waits until something asks to sleep, and answers with the duration it asked for.
    public func nextSleep() async -> Duration {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Duration? in
                guard !state.unobserved.isEmpty else {
                    state.observers.append(continuation)
                    return nil
                }
                return state.unobserved.removeFirst()
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    /// Releases the oldest outstanding sleep, advancing `now` by the duration it asked for.
    ///
    /// Returns `false` when nothing was waiting, so a test can assert the difference between "the
    /// scheduler is parked" and "the scheduler already gave up".
    @discardableResult
    public func fireOldestSleep() -> Bool {
        let waiter = state.withLock { state -> Waiter? in
            guard !state.waiters.isEmpty else { return nil }
            let waiter = state.waiters.removeFirst()
            state.now = state.now.adding(waiter.duration)
            return waiter
        }
        guard let waiter else { return false }
        waiter.continuation.resume()
        return true
    }

    public func sleep(for duration: Duration) async throws {
        let id = state.withLock { state -> Int in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, duration: duration, continuation: continuation)
            }
        } onCancel: {
            cancel(id)
        }
    }

    private func register(
        id: Int,
        duration: Duration,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        enum Resolution {
            case cancelled
            case observed(CheckedContinuation<Duration, Never>)
            case parked
        }
        let resolution = state.withLock { state -> Resolution in
            state.recorded.append(duration)
            guard state.cancelled.remove(id) == nil else { return .cancelled }
            state.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
            guard state.observers.isEmpty else { return .observed(state.observers.removeFirst()) }
            state.unobserved.append(duration)
            return .parked
        }
        switch resolution {
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .observed(let observer): observer.resume(returning: duration)
        case .parked: break
        }
    }

    private func cancel(_ id: Int) {
        let waiter = state.withLock { state -> Waiter? in
            guard let index = state.waiters.firstIndex(where: { $0.id == id }) else {
                state.cancelled.insert(id)
                return nil
            }
            return state.waiters.remove(at: index)
        }
        waiter?.continuation.resume(throwing: CancellationError())
    }
}
