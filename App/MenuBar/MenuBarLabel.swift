import SwiftUI
import UsageKit

/// The status item. The `Canvas`-drawn ring and its threshold colours land in the Liquid Glass
/// pass; this shows the worst-case percentage across every discovered account.
struct MenuBarLabel: View {
    let worstFraction: Double?

    var body: some View {
        if let worstFraction {
            Label(
                worstFraction.formatted(.percent.precision(.fractionLength(0))),
                systemImage: "chart.bar.fill"
            )
        } else {
            Image(systemName: "chart.bar.fill")
                .accessibilityLabel("Usage")
        }
    }

    /// The highest window fraction any account currently reports, or `nil` before the first
    /// successful refresh.
    static func worstFraction(in accounts: [AccountState]) -> Double? {
        accounts.compactMap(\.report).flatMap(\.windows).map(\.usedFraction).max()
    }
}
