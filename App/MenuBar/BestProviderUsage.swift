import Foundation
import UsageKit

/// The provider a new task should go to: the one whose bottleneck window has the most room left.
///
/// Eligibility is strict so the label never recommends a guess. A provider competes only when it
/// has at least one discovered account and every one of its discovered accounts carries a
/// non-partial report, no current error, and at least one usage window. A cached report paired
/// with a failed refresh stays visible in the popover but does not compete here, and a
/// credits-only report has no capacity value to rank. Provider headroom is the minimum remaining
/// fraction across every window of every account — the bottleneck a new task would actually hit.
struct BestProviderUsage: Equatable {
    let providerID: ProviderID
    let displayName: String
    let remainingFraction: Double

    /// The best eligible provider, or `nil` when none qualifies.
    ///
    /// Ties break by `registry.providerIDs` order and then by raw provider ID, so equal headroom
    /// always selects the same provider.
    static func select(
        accounts: [AccountState],
        registry: ProviderRegistry
    ) -> BestProviderUsage? {
        var order: [ProviderID] = []
        var grouped: [ProviderID: [AccountState]] = [:]
        for state in accounts {
            let id = state.account.key.providerID
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(state)
        }

        var best: BestProviderUsage?
        var bestPosition = Int.max
        for id in order {
            guard let states = grouped[id], let headroom = headroom(of: states) else { continue }
            let position = registry.providerIDs.firstIndex(of: id) ?? registry.providerIDs.count
            let candidate = BestProviderUsage(
                providerID: id,
                displayName: registry.provider(for: id)?.displayName ?? id.rawValue.capitalized,
                remainingFraction: headroom
            )
            guard let current = best else {
                best = candidate
                bestPosition = position
                continue
            }
            if candidate.remainingFraction > current.remainingFraction
                || (candidate.remainingFraction == current.remainingFraction
                    && (position < bestPosition
                        || (position == bestPosition
                            && candidate.providerID.rawValue < current.providerID.rawValue)))
            {
                best = candidate
                bestPosition = position
            }
        }
        return best
    }

    /// The provider's bottleneck, or `nil` when any account disqualifies the whole provider.
    private static func headroom(of states: [AccountState]) -> Double? {
        guard !states.isEmpty else { return nil }
        var minimum: Double?
        for state in states {
            guard let report = state.report, state.lastError == nil, !report.isPartial,
                !report.windows.isEmpty
            else { return nil }
            for window in report.windows {
                minimum = Swift.min(minimum ?? .infinity, window.remainingFraction)
            }
        }
        return minimum
    }
}
