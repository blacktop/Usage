import SwiftUI
import UsageKit

struct ProviderMetricList: View {
    let groups: [ProviderUsagePresentation.WindowGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups) { group in
                ProviderMetricGroup(group: group)
            }
        }
    }
}

private struct ProviderMetricGroup: View {
    let group: ProviderUsagePresentation.WindowGroup

    private var commonFootnote: String? {
        let footnotes = group.meters.compactMap { UsageWindowText.footnote(for: $0.window) }
        guard footnotes.count == group.meters.count,
            let first = footnotes.first,
            footnotes.dropFirst().allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(group.label)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                if let commonFootnote {
                    Text(commonFootnote)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            ForEach(group.meters) { meter in
                ProviderAccountMeter(
                    meter: meter,
                    showsFootnote: commonFootnote == nil
                )
            }
        }
    }
}

private struct ProviderAccountMeter: View {
    let meter: ProviderUsagePresentation.WindowGroup.Meter
    let showsFootnote: Bool

    private var tint: Color { AccountTint.color(at: meter.account.colorIndex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                CompactProgressBar(value: meter.window.remainingFraction, tint: tint)
                Text(UsageWindowText.percent(meter.window.remainingFraction))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(tint)
                    .frame(width: 58, alignment: .trailing)
            }
            if showsFootnote, let footnote = UsageWindowText.footnote(for: meter.window) {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 66)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(meter.account.label), \(meter.window.label)")
        .accessibilityValue(UsageWindowText.percent(meter.window.remainingFraction))
        .accessibilityHint(UsageWindowText.footnote(for: meter.window) ?? "")
    }
}

private struct CompactProgressBar: View {
    let value: Double
    let tint: Color

    private var clampedValue: Double { min(max(value, 0), 1) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.primary.opacity(0.09))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * clampedValue)
            }
        }
        .frame(height: 6)
        .animation(.snappy(duration: 0.35), value: clampedValue)
    }
}

struct ProviderCreditsGroup: View {
    let credits: [ProviderUsagePresentation.Credit]

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 8, alignment: .leading)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Credits")
                .font(.caption.weight(.medium))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
                ForEach(credits) { credit in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(AccountTint.color(at: credit.account.colorIndex))
                            .frame(width: 6, height: 6)
                        Text(CreditBalanceText.text(for: credit.balance))
                            .font(.caption2.monospacedDigit())
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "\(credit.account.label) credits, "
                            + CreditBalanceText.text(for: credit.balance)
                    )
                }
            }
        }
    }
}

enum CreditBalanceText {
    static func text(for credits: CreditBalance) -> String {
        let remaining = amount(credits.remaining, in: credits.currency)
        guard let granted = credits.granted else { return remaining }
        return "\(remaining) of \(amount(granted, in: credits.currency))"
    }

    private static func amount(_ value: Decimal, in currency: String?) -> String {
        guard let currency else {
            return value.formatted(.number.precision(.fractionLength(0...2)))
        }
        return value.formatted(.currency(code: currency))
    }
}

enum UsageWindowText {
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0))) + " left"
    }

    static func footnote(for window: UsageWindow) -> String? {
        let parts = [detail(window.detail), reset(window.resetsAt)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func detail(_ detail: UsageDetail?) -> String? {
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

    private static func reset(_ date: Date?) -> String? {
        guard let date else { return nil }
        return "resets \(date.formatted(.relative(presentation: .numeric)))"
    }
}
