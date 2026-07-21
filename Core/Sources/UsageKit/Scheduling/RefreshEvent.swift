import Foundation

/// Everything the coordinator tells the outside world.
///
/// The coordinator never touches a store, a view, or a persisted file. It emits these, and whoever
/// owns UI state decides what they mean — which is what keeps scheduling testable without a store
/// and the store testable without a scheduler.
public enum RefreshEvent: Sendable, Hashable {
    case discovered(accounts: [ProviderAccount], provider: ProviderID, at: Date)
    case discoveryFailed(error: UsageError, provider: ProviderID)
    /// The account now has a future deadline and no refresh in flight.
    case scheduled(key: AccountKey)
    case began(key: AccountKey, at: Date)
    case succeeded(report: UsageReport, at: Date)
    case failed(error: UsageError, key: AccountKey, at: Date)
}

/// Where `RefreshEvent`s go. One method, so the app's main-actor store can be the whole
/// implementation and a test can be an actor that collects them.
public protocol RefreshEventSink: Sendable {
    func receive(_ event: RefreshEvent) async
}
