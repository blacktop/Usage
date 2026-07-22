import SwiftUI
import UsageKit

/// One compact provider surface: account legend, grouped usage meters, and account-specific issues.
struct ProviderUsageCard: View {
    let section: PopoverAccountSection
    let onRetry: (AccountKey, Bool) -> Void

    private let presentation: ProviderUsagePresentation

    init(
        section: PopoverAccountSection,
        onRetry: @escaping (AccountKey, Bool) -> Void
    ) {
        self.section = section
        self.onRetry = onRetry
        presentation = ProviderUsagePresentation(section: section)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderCardHeader(
                title: section.displayName,
                accountCount: presentation.discoveredAccountCount
            )
            ProviderAccountLegend(accounts: presentation.accounts)
            ProviderMetricList(groups: presentation.windowGroups)
            if !presentation.credits.isEmpty {
                ProviderCreditsGroup(credits: presentation.credits)
            }
            ProviderAccountIssues(accounts: presentation.accounts, onRetry: onRetry)
            ProviderFreshness(presentation: presentation)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: .rect(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityIdentifier("provider-card-\(section.id.rawValue)")
    }
}

private struct ProviderCardHeader: View {
    let title: String
    let accountCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Text("\(accountCount) \(accountCount == 1 ? "account" : "accounts")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ProviderAccountLegend: View {
    let accounts: [ProviderUsagePresentation.Account]

    private let columns = [
        GridItem(.flexible(), spacing: 12, alignment: .leading),
        GridItem(.flexible(), alignment: .leading),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(accounts) { account in
                ProviderLegendItem(account: account)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Account colors")
    }
}

private struct ProviderLegendItem: View {
    let account: ProviderUsagePresentation.Account

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Circle()
                    .fill(AccountTint.color(at: account.colorIndex))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(account.label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                AccountRefreshMark(state: account.state)
            }
            if let plan = account.plan {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.leading, 13)
            }
        }
        .accessibilityElement(children: .combine)
        .help(account.label)
    }
}

private struct AccountRefreshMark: View {
    let state: AccountState?

    var body: some View {
        Group {
            switch state.map(AccountRefreshIndicator.forState) ?? nil {
            case .loading:
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Refreshing")
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Last refresh failed")
            case nil:
                EmptyView()
            }
        }
        .font(.caption2)
    }
}

private struct ProviderFreshness: View {
    let presentation: ProviderUsagePresentation

    var body: some View {
        if let text = ProviderFreshnessText.text(for: presentation) {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: "clock")
                    .accessibilityHidden(true)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .accessibilityElement(children: .combine)
        }
    }
}

enum AccountTint {
    static func color(at index: Int) -> Color {
        switch index {
        case 0: .blue
        case 1: .green
        case 2: .orange
        case 3: .purple
        case 4: .pink
        case 5: .teal
        case 6: .indigo
        case 7: .mint
        default:
            Color(
                hue: (Double(index) * 0.618_033_988_75).truncatingRemainder(dividingBy: 1),
                saturation: 0.72,
                brightness: 0.92
            )
        }
    }
}
