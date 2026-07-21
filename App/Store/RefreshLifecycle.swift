import AppKit
import CoreGraphics

/// Turns macOS sleep and wake into refresh decisions.
///
/// Waking with the lid still closed or every display asleep is not a reason to talk to three
/// undocumented endpoints, so the wake handler asks the display first. Both callbacks are plain
/// closures, which is what lets this be tested by posting a notification instead of sleeping a Mac.
@MainActor
final class RefreshLifecycle {
    private let center: NotificationCenter
    private let isDisplayAwake: @Sendable () -> Bool
    private let onWake: @MainActor () -> Void
    private let onSleep: @MainActor () -> Void
    private var observers: [any NSObjectProtocol] = []

    init(
        center: NotificationCenter = NSWorkspace.shared.notificationCenter,
        isDisplayAwake: @escaping @Sendable () -> Bool = RefreshLifecycle.mainDisplayIsAwake,
        onWake: @escaping @MainActor () -> Void,
        onSleep: @escaping @MainActor () -> Void
    ) {
        self.center = center
        self.isDisplayAwake = isDisplayAwake
        self.onWake = onWake
        self.onSleep = onSleep
    }

    nonisolated static func mainDisplayIsAwake() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    func start() {
        guard observers.isEmpty else { return }
        observers = [
            observe(NSWorkspace.didWakeNotification) { $0.handleWake() },
            observe(NSWorkspace.willSleepNotification) { $0.handleSleep() },
        ]
    }

    func stop() {
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    /// Refreshes on wake, unless the machine woke with its displays still off.
    func handleWake() {
        guard isDisplayAwake() else { return }
        onWake()
    }

    func handleSleep() {
        onSleep()
    }

    private func observe(
        _ name: Notification.Name,
        handler: @escaping @MainActor (RefreshLifecycle) -> Void
    ) -> any NSObjectProtocol {
        // `queue: nil` delivers on the posting thread, and NSWorkspace posts these on the main
        // thread, so the assumption below is the documented delivery contract rather than a hope.
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }
}
