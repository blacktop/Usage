import AppKit
import Testing

@testable import Usage

@Suite("Refresh lifecycle")
@MainActor
struct RefreshLifecycleTests {
    /// Counts what the lifecycle asked for, without needing a coordinator or a real Mac to sleep.
    private final class Calls {
        var wakes = 0
        var sleeps = 0
    }

    private func lifecycle(
        center: NotificationCenter,
        calls: Calls,
        displayAwake: Bool
    ) -> RefreshLifecycle {
        RefreshLifecycle(
            center: center,
            isDisplayAwake: { displayAwake },
            onWake: { calls.wakes += 1 },
            onSleep: { calls.sleeps += 1 }
        )
    }

    @Test("Waking with a display on triggers exactly one refresh")
    func wakeRefreshesOnce() {
        let center = NotificationCenter()
        let calls = Calls()
        let lifecycle = lifecycle(center: center, calls: calls, displayAwake: true)
        lifecycle.start()

        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(calls.wakes == 1)
        #expect(calls.sleeps == 0)
    }

    @Test("Waking with every display asleep refreshes nothing")
    func wakeWithoutADisplayDoesNothing() {
        let center = NotificationCenter()
        let calls = Calls()
        let lifecycle = lifecycle(center: center, calls: calls, displayAwake: false)
        lifecycle.start()

        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(calls.wakes == 0)
    }

    @Test("Going to sleep suspends the schedule")
    func sleepSuspends() {
        let center = NotificationCenter()
        let calls = Calls()
        let lifecycle = lifecycle(center: center, calls: calls, displayAwake: true)
        lifecycle.start()

        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        #expect(calls.sleeps == 1)
        #expect(calls.wakes == 0)
    }

    @Test("Starting twice does not double-subscribe")
    func repeatedStartsSubscribeOnce() {
        let center = NotificationCenter()
        let calls = Calls()
        let lifecycle = lifecycle(center: center, calls: calls, displayAwake: true)
        lifecycle.start()
        lifecycle.start()

        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(calls.wakes == 1)
    }

    @Test("Stopping ends every subscription")
    func stopUnsubscribes() {
        let center = NotificationCenter()
        let calls = Calls()
        let lifecycle = lifecycle(center: center, calls: calls, displayAwake: true)
        lifecycle.start()
        lifecycle.stop()

        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        #expect(calls.wakes == 0)
        #expect(calls.sleeps == 0)
    }
}
