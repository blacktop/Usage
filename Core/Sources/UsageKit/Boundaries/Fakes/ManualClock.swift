import Foundation
import Synchronization

/// `UsageClock` whose time only moves when a test moves it.
///
/// `sleep(for:)` does not suspend: it records the requested duration and advances `now`, so
/// scheduling logic can be exercised without real waiting.
public final class ManualClock: UsageClock, Sendable {
    private struct State {
        var now: Date
        var sleeps: [Duration] = []
    }

    private let state: Mutex<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        state = Mutex(State(now: now))
    }

    public var now: Date {
        state.withLock { $0.now }
    }

    /// Durations passed to `sleep(for:)`, in call order.
    public var recordedSleeps: [Duration] {
        state.withLock { $0.sleeps }
    }

    public func advance(by duration: Duration) {
        state.withLock { $0.now = $0.now.adding(duration) }
    }

    public func sleep(for duration: Duration) async throws {
        state.withLock {
            $0.sleeps.append(duration)
            $0.now = $0.now.adding(duration)
        }
    }
}
