import Foundation

@testable import UsageKit

/// Collects everything a coordinator emits, so a test can assert on outcomes rather than on the
/// coordinator's internals.
actor EventLog: RefreshEventSink {
    private(set) var events: [RefreshEvent] = []

    func receive(_ event: RefreshEvent) async {
        events.append(event)
    }

    func reports(for key: AccountKey) -> [UsageReport] {
        events.compactMap { event in
            guard case .succeeded(let report, _) = event, report.accountKey == key else {
                return nil
            }
            return report
        }
    }

    func failures(for key: AccountKey) -> [UsageError] {
        events.compactMap { event in
            guard case .failed(let error, let failed, _) = event, failed == key else { return nil }
            return error
        }
    }

    func beganCount(for key: AccountKey) -> Int {
        events.filter { event in
            guard case .began(let began, _) = event else { return false }
            return began == key
        }
        .count
    }

    func discoveredAccounts(for provider: ProviderID) -> [ProviderAccount] {
        events.reduce(into: []) { result, event in
            guard case .discovered(let accounts, let id, _) = event, id == provider else { return }
            result = accounts
        }
    }

    func discoveryFailures(for provider: ProviderID) -> [UsageError] {
        events.compactMap { event in
            guard case .discoveryFailed(let error, let id) = event, id == provider else {
                return nil
            }
            return error
        }
    }
}
