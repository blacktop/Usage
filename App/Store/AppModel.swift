import Foundation
import Observation
import UsageKit

/// The app's composition root: it owns the store, the coordinator, and the sleep/wake bridge, and
/// is the only place the three know about each other.
///
/// The store stays free of scheduling and the coordinator stays free of UI; this holds both and
/// forwards the things a user can actually ask for: refresh now and approve a protected credential.
@Observable
@MainActor
final class AppModel {
    let store: UsageStore
    /// Enabled configured folders, including ones that do not hold a usable account yet.
    private(set) var configuredProfiles: [ConfiguredProfileStatus] = []
    /// The very store the coordinator's context discovers through.
    ///
    /// Held rather than rebuilt so that editing a root and rediscovering are the same store: a
    /// second `UserDefaultsProfileRootStore` would be a second view of the same suite, and a
    /// Settings edit made against it would race the refresh that is supposed to observe it.
    @ObservationIgnored let profileRoots: any ProfileRootStore
    /// The providers the coordinator rediscovers through, so Settings groups roots under exactly
    /// the providers that will read them rather than under a second, drifting list.
    @ObservationIgnored let registry: ProviderRegistry
    /// The very file system the coordinator's context reads, so a Settings existence check and a
    /// discovery read agree about which documents are there.
    @ObservationIgnored let fileSystem: any ProviderFileSystem

    @ObservationIgnored private let coordinator: RefreshCoordinator
    @ObservationIgnored private let interactiveCredentials: any CredentialSource
    @ObservationIgnored private var lifecycle: RefreshLifecycle?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var profileLoadGeneration = 0

    init(
        registry: ProviderRegistry,
        context: ProviderContext,
        interactiveCredentials: (any CredentialSource)? = nil,
        configuration: RefreshCoordinator.Configuration = RefreshCoordinator.Configuration()
    ) {
        let store = UsageStore()
        self.store = store
        self.registry = registry
        profileRoots = context.profileRoots
        fileSystem = context.fileSystem
        self.interactiveCredentials = interactiveCredentials ?? context.credentials
        coordinator = RefreshCoordinator(
            registry: registry,
            context: context,
            sink: store,
            configuration: configuration
        )
    }

    /// The app's own wiring: every implemented provider, discovering through the shared
    /// profile-root suite and nothing else.
    ///
    /// No `PreviewProvider`: its three synthetic accounts belong to the suites that exercise the
    /// store and the popover, not to a shipped menu bar showing a user their real quota.
    static func live() -> AppModel {
        let context = ProviderContext.system()
        return AppModel(
            registry: .agents,
            context: context,
            interactiveCredentials: SystemCredentialSource(
                fileSystem: context.fileSystem,
                interaction: UserInitiatedInteractionPolicy()
            )
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
        await reloadConfiguredProfiles()
        await coordinator.refresh()
    }

    /// Coalesces with whatever is already in flight and never bypasses an active cooldown.
    func refreshNow() async {
        await reloadConfiguredProfiles()
        await coordinator.refresh()
    }

    /// User-initiated recovery for a Keychain-backed account.
    ///
    /// This is intentionally separate from `refreshNow()`: scheduled and generic manual refreshes
    /// must remain unable to raise credential UI. The coordinator retains the secret-free locator,
    /// performs one approval read, and then retries through its ordinary background context.
    func approveCredentialAccess(for key: AccountKey) async {
        await coordinator.approveCredentialAccess(for: key, using: interactiveCredentials)
    }

    /// Refreshes the non-secret configured-folder projection used by the popover.
    ///
    /// A generation stamp prevents a slower older read from replacing a newer Settings edit. A
    /// failed read keeps the last good projection while provider discovery reports its own error.
    private func reloadConfiguredProfiles() async {
        profileLoadGeneration += 1
        let generation = profileLoadGeneration
        guard let collection = try? await profileRoots.load(), generation == profileLoadGeneration
        else { return }
        configuredProfiles = collection.profiles
            .filter(\.isEnabled)
            .map { profile in
                ConfiguredProfileStatus(
                    profile: profile,
                    hasCredentialDocument: ProviderCredentialDocuments.exists(
                        below: profile,
                        using: fileSystem
                    )
                )
            }
    }

    private func refreshInBackground() {
        Task { await refreshNow() }
    }

    private func suspendInBackground() {
        Task { await coordinator.suspend() }
    }
}
