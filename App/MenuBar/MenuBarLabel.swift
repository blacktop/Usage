import SwiftUI
import UsageKit

/// The status item: which agent to hand work to, and how much room it has left.
///
/// The `Canvas`-drawn ring and its threshold colours land in the Liquid Glass pass; this shows the
/// best eligible provider by remaining capacity, selected by `BestProviderUsage`.
struct MenuBarLabel: View {
    let best: BestProviderUsage?

    var body: some View {
        if let best {
            let percentage = best.remainingFraction.formatted(
                .percent.precision(.fractionLength(0))
            )
            Label(
                "\(best.displayName) \(percentage)",
                systemImage: "chart.bar.fill"
            )
            .accessibilityLabel(
                "\(best.displayName) has the most capacity left: \(percentage)"
            )
        } else {
            Image(systemName: "chart.bar.fill")
                .accessibilityLabel("Usage")
        }
    }
}
