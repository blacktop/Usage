import SwiftUI
import UsageKit

/// One usage window: label, absolute detail, a bar clamped for rendering, and its reset time.
struct UsageWindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.caption)
                Spacer()
                Text(Self.percentText(window.usedFraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Self.tint(for: window.usedFraction))
            }
            ProgressView(value: window.renderFraction)
                .progressViewStyle(.linear)
                .tint(Self.tint(for: window.usedFraction))
            if let footnote = Self.footnote(for: window) {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The stored fraction is shown verbatim so an over-quota window reads as over quota; only
    /// the bar is clamped.
    private static func percentText(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private static func tint(for fraction: Double) -> Color {
        switch fraction {
        case ..<0.8: .accentColor
        case ..<0.95: .orange
        default: .red
        }
    }

    private static func footnote(for window: UsageWindow) -> String? {
        let parts = [detailText(window.detail), resetText(window.resetsAt)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func detailText(_ detail: UsageDetail?) -> String? {
        switch detail {
        case .none:
            nil
        case .count(let used, let limit):
            "\(used.formatted()) of \(limit.formatted())"
        case .money(let spent, let budget, let currency):
            spent.formatted(.currency(code: currency))
                + " of " + budget.formatted(.currency(code: currency))
        }
    }

    private static func resetText(_ resetsAt: Date?) -> String? {
        guard let resetsAt else { return nil }
        return "resets \(resetsAt.formatted(.relative(presentation: .numeric)))"
    }
}
