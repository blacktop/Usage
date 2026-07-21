import Foundation
import Observation
import UsageKit

/// The app's single source of UI truth.
///
/// It owns projected account state and nothing else: no networking, no credential handles, no
/// schedule. Everything it knows arrives as a `RefreshEvent` from `RefreshCoordinator`, and every
/// transition goes through `AccountStateTable`, which is where stale-while-revalidate lives — a
/// loading or failed refresh never blanks the last good report.
@Observable
@MainActor
final class UsageStore: RefreshEventSink {
    private(set) var table = AccountStateTable()
    private(set) var discoveryFailures: [ProviderID: UsageError] = [:]

    init() {}

    var accounts: [AccountState] { table.accounts }

    /// Whether any account has a fetch in flight right now.
    var isRefreshing: Bool { accounts.contains { $0.refreshPhase == .loading } }

    func receive(_ event: RefreshEvent) async {
        apply(event)
    }

    func apply(_ event: RefreshEvent) {
        switch event {
        case .discovered(let accounts, let provider, let date):
            discoveryFailures[provider] = nil
            table.replaceDiscovered(accounts, forProvider: provider, at: date)
        case .discoveryFailed(let error, let provider):
            discoveryFailures[provider] = error
        case .scheduled(let key):
            table.markScheduled(key)
        case .began(let key, let date):
            table.beginRefresh(key, at: date)
        case .succeeded(let report, let date):
            table.apply(report, at: date)
        case .failed(let error, let key, let date):
            table.apply(error, for: key, at: date)
        }
    }
}
