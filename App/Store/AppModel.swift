import Foundation
import Observation
import UsageKit

/// The app's composition root: it owns the store, the coordinator, and the sleep/wake bridge, and
/// is the only place the three know about each other.
///
/// The store stays free of scheduling and the coordinator stays free of UI; this holds both and
/// forwards the three things a user can actually ask for — refresh now, the popover opened, the
/// popover closed.
@Observable
@MainActor
final class AppModel {
    let store: UsageStore

    @ObservationIgnored private let coordinator: RefreshCoordinator
    @ObservationIgnored private var lifecycle: RefreshLifecycle?
    @ObservationIgnored private var hasStarted = false

    init(
        registry: ProviderRegistry,
        context: ProviderContext,
        configuration: RefreshCoordinator.Configuration = RefreshCoordinator.Configuration()
    ) {
        let store = UsageStore()
        self.store = store
        coordinator = RefreshCoordinator(
            registry: registry,
            context: context,
            sink: store,
            configuration: configuration
        )
    }

    /// The app's own wiring: the Codex vertical slice plus the synthetic preview accounts.
    ///
    /// Registry membership is per host, because Keychain access is. Claude additionally waits on
    /// the Keychain feasibility gate, which is an explicit user approval this build does not have,
    /// so neither it nor Copilot is here yet — the same reason `ProviderRegistry.commandLine`
    /// holds only Codex.
    static func live() -> AppModel {
        AppModel(
            registry: ProviderRegistry(providers: [CodexProvider(), UsageKit.PreviewProvider()]),
            context: .system()
        )
    }

    /// Discovers accounts, runs the first refresh, and starts listening for sleep and wake.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        let lifecycle = RefreshLifecycle(
            onWake: { [weak self] in self?.refreshInBackground() },
            onSleep: { [weak self] in self?.suspendInBackground() }
        )
        lifecycle.start()
        self.lifecycle = lifecycle
        await coordinator.refresh()
    }

    /// Coalesces with whatever is already in flight and never bypasses an active cooldown.
    func refreshNow() async {
        await coordinator.refresh()
    }

    private func refreshInBackground() {
        Task { await coordinator.refresh() }
    }

    private func suspendInBackground() {
        Task { await coordinator.suspend() }
    }
}
