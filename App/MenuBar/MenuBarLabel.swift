import SwiftUI
import UsageKit

/// The status item. The `Canvas`-drawn ring and its threshold colours land in the Liquid Glass
/// pass; this shows the least capacity remaining across every discovered account.
struct MenuBarLabel: View {
    let remainingFraction: Double?

    var body: some View {
        if let remainingFraction {
            let percentage = remainingFraction.formatted(
                .percent.precision(.fractionLength(0))
            )
            Label(
                percentage,
                systemImage: "chart.bar.fill"
            )
            .accessibilityLabel("\(percentage) remaining")
        } else {
            Image(systemName: "chart.bar.fill")
                .accessibilityLabel("Usage")
        }
    }

    /// The least remaining capacity any account currently reports, or `nil` before the first
    /// successful refresh. An exhausted or over-quota window contributes zero, never a negative.
    static func leastRemainingFraction(in accounts: [AccountState]) -> Double? {
        accounts.compactMap(\.report).flatMap(\.windows).map(\.remainingFraction).min()
    }
}
