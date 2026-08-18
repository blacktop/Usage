import Foundation
import UsageKit

/// One user-facing alert: an account's credential now needs an explicit approval in the app.
///
/// Carries only the account's identity and its non-secret display label. Error details stay in the
/// popover, which is where the Approve action lives.
struct CredentialApprovalAlert: Sendable, Hashable {
    let accountKey: AccountKey
    let accountName: String
}

/// Where credential-approval alerts go. Production posts a platform notification; tests collect.
///
/// `nonisolated` opts out of the target's MainActor default: the notifier is an actor and delivery
/// talks to the notification center, so nothing here needs the main thread.
nonisolated protocol CredentialApprovalPresenter: Sendable {
    func present(_ alert: CredentialApprovalAlert) async
    /// Retracts the account's alert once approval is no longer needed, so a notification the
    /// user has not clicked yet cannot outlive the problem it reports.
    func withdraw(for accountKey: AccountKey) async
}

/// Turns the first approval-required refresh failure per account into one alert.
///
/// Claude Code recreates its Keychain item when it rotates a credential, and every recreation
/// silently voids the approval the user last granted. Without an alert the popover shows a stale
/// card until the user happens to open it; with one, the gap between rotation and re-approval is
/// however long the user takes to click.
///
/// Alerting is edge-triggered: the flag set on the first `interactionForbidden` failure is cleared
/// only by that account's next successful report, which also withdraws the delivered notification
/// so a stale "needs approval" cannot sit in Notification Center after the user has already fixed
/// it. A five-minute refresh cadence cannot repeat the alert, and a later rotation alerts again.
/// A retired account's flag and cached name are dropped with it, the same way the coordinator
/// drops its schedule — and, like the coordinator, an empty discovery retires nothing, because
/// providers answer empty both for "gone" and for "unreadable right now".
actor CredentialApprovalNotifier: RefreshEventSink {
    private let presenter: any CredentialApprovalPresenter
    private var accountNames: [AccountKey: String] = [:]
    private var alerted: Set<AccountKey> = []

    init(presenter: any CredentialApprovalPresenter) {
        self.presenter = presenter
    }

    func receive(_ event: RefreshEvent) async {
        switch event {
        case .discovered(let accounts, let provider, _):
            guard !accounts.isEmpty else { return }
            for account in accounts {
                accountNames[account.key] = account.displayName
            }
            let surviving = Set(accounts.map(\.key))
            alerted = alerted.filter { $0.providerID != provider || surviving.contains($0) }
            accountNames = accountNames.filter {
                $0.key.providerID != provider || surviving.contains($0.key)
            }
        case .failed(let error, let key, _):
            guard error.requiresCredentialApproval, !alerted.contains(key) else { return }
            alerted.insert(key)
            await presenter.present(
                CredentialApprovalAlert(
                    accountKey: key,
                    accountName: accountNames[key] ?? key.providerID.rawValue
                )
            )
        case .succeeded(let report, _):
            guard alerted.remove(report.accountKey) != nil else { return }
            await presenter.withdraw(for: report.accountKey)
        case .discoveryFailed, .scheduled, .began:
            break
        }
    }
}
