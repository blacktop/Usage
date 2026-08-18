import Foundation
import UsageKit

/// A compact, provider-wide projection of account usage for the popover.
///
/// The projection is value-only and deterministic: views do not group or sort reports while
/// rendering, and each account keeps the same color index everywhere inside its provider card.
struct ProviderUsagePresentation {
    struct Account: Identifiable {
        enum ID: Hashable {
            case discovered(AccountKey)
            case configured(ProfileRootID)
        }

        let id: ID
        let label: String
        let colorIndex: Int
        let state: AccountState?
        let configuredProfile: ConfiguredProfileStatus?

        var plan: String? { state?.report?.plan }
    }

    struct WindowGroup: Identifiable {
        struct Meter: Identifiable {
            let account: Account
            let window: UsageWindow

            var id: Account.ID { account.id }
        }

        let id: WindowID
        let label: String
        let meters: [Meter]
    }

    struct Credit: Identifiable {
        let account: Account
        let balance: CreditBalance

        var id: Account.ID { account.id }
    }

    let accounts: [Account]
    let windowGroups: [WindowGroup]
    let credits: [Credit]

    /// Accounts backed by another agent's Keychain row, paired with the key an approval targets.
    ///
    /// These are the credentials whose read grant can silently die under a healthy-looking card:
    /// stale-while-revalidate keeps the last report visible and the mirror keeps fresh data
    /// flowing, so the user needs a way to force a re-approval that no error row is offering.
    var reapprovableAccounts: [(key: AccountKey, account: Account)] {
        accounts.compactMap { account in
            guard case .discovered(let key) = account.id,
                account.state?.account.credentialKinds.contains(.keychain) == true
            else { return nil }
            return (key, account)
        }
    }

    init(section: PopoverAccountSection) {
        let discovered = section.accounts.enumerated().map { index, state in
            Account(
                id: .discovered(state.account.key),
                label: state.account.displayName ?? "Unknown account",
                colorIndex: index,
                state: state,
                configuredProfile: nil
            )
        }
        let configured = section.unrepresentedProfiles.enumerated().map { index, status in
            Account(
                id: .configured(status.id),
                label: status.profile.label,
                colorIndex: discovered.count + index,
                state: nil,
                configuredProfile: status
            )
        }
        accounts = discovered + configured

        var order: [WindowID] = []
        var labels: [WindowID: String] = [:]
        var grouped: [WindowID: [WindowGroup.Meter]] = [:]
        for account in discovered {
            for window in account.state?.report?.windows ?? [] {
                if grouped[window.id] == nil {
                    order.append(window.id)
                    labels[window.id] = window.label
                }
                grouped[window.id, default: []].append(
                    WindowGroup.Meter(account: account, window: window)
                )
            }
        }
        windowGroups = order.compactMap { id in
            guard let label = labels[id], let meters = grouped[id] else { return nil }
            return WindowGroup(id: id, label: label, meters: meters)
        }

        credits = discovered.compactMap { account in
            guard let balance = account.state?.report?.credits else { return nil }
            return Credit(account: account, balance: balance)
        }
    }

    var oldestCaptureDate: Date? {
        accounts.compactMap { $0.state?.report?.capturedAt }.min()
    }

    var discoveredAccountCount: Int {
        accounts.lazy.compactMap(\.state).count
    }

    var hasCachedFailure: Bool {
        accounts.contains { $0.state?.report != nil && $0.state?.lastError != nil }
    }
}

enum AccountRefreshIndicator: Equatable {
    case loading
    case failed

    static func forState(_ state: AccountState) -> AccountRefreshIndicator? {
        if state.refreshPhase == .loading { return .loading }
        if state.lastError != nil { return .failed }
        return nil
    }
}

enum ProviderFreshnessText {
    static func text(for presentation: ProviderUsagePresentation) -> String? {
        guard let capturedAt = presentation.oldestCaptureDate else { return nil }
        let age = capturedAt.formatted(.relative(presentation: .numeric))
        return presentation.hasCachedFailure
            ? "showing cached data from \(age)"
            : "updated \(age)"
    }
}
