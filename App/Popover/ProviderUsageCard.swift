import SwiftUI
import UsageKit

/// One compact provider surface: account legend, grouped usage meters, and account-specific issues.
struct ProviderUsageCard: View {
    let section: PopoverAccountSection
    let glass: LiquidGlassStyle
    let onRetry: (AccountKey, Bool) -> Void

    private let presentation: ProviderUsagePresentation

    init(
        section: PopoverAccountSection,
        glass: LiquidGlassStyle,
        onRetry: @escaping (AccountKey, Bool) -> Void
    ) {
        self.section = section
        self.glass = glass
        self.onRetry = onRetry
        presentation = ProviderUsagePresentation(section: section)
    }

    var body: some View {
        // Glass here is legitimate only once the window backdrop is fully faded: the card then
        // samples the desktop. With any backdrop present it would be glass on glass, which
        // renders as unreadable murk — so the card falls back to a flat content-layer fill.
        if glass.usesGlassIslands {
            content
                .glassEffect(.regular, in: .rect(cornerRadius: glass.cardCornerRadius))
        } else {
            content
                .background(
                    .primary.opacity(glass.cardFillOpacity),
                    in: .rect(cornerRadius: glass.cardCornerRadius)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: glass.cardCornerRadius)
                        .stroke(.primary.opacity(0.07), lineWidth: 1)
                }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProviderCardHeader(
                title: section.displayName,
                accountCount: presentation.discoveredAccountCount
            )
            // A single account's tint dot restates nothing the meters don't already carry, so
            // the legend earns its rows only when there is more than one account to tell apart.
            if presentation.accounts.count > 1 {
                ProviderAccountLegend(accounts: presentation.accounts)
            }
            ProviderMetricList(groups: presentation.windowGroups)
            if !presentation.credits.isEmpty {
                ProviderCreditsGroup(credits: presentation.credits)
            }
            ProviderAccountIssues(accounts: presentation.accounts, onRetry: onRetry)
            ProviderFreshness(presentation: presentation)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The forced path to the approval dialog. The error row's Approve button exists only
        // while a failure is showing; a dead grant hiding behind cached or mirrored data has no
        // error row, and right-clicking the card is how the user reaches the dialog anyway.
        // During a provider-mandated cooldown the entry is inert and says why: the
        // coordinator would defer the request anyway, and a menu item that silently does
        // nothing reads as broken. `Date()` is sampled when the menu opens, which is the
        // user-initiated instant the comparison is about.
        .contextMenu {
            ForEach(presentation.reapprovableAccounts, id: \.account.id) { entry in
                let issue = ProviderAccountIssuePresentation(account: entry.account)
                // A bare Text renders as a disabled, non-interactive menu item.
                if let label = issue.cooldownLabel(now: Date()) {
                    Text(label)
                } else {
                    Button("Re-approve Keychain access for \(entry.account.label)…") {
                        onRetry(entry.key, true)
                    }
                }
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        HStack(spacing: 6) {
            Circle()
                .fill(AccountTint.color(at: account.colorIndex))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(account.label)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .layoutPriority(1)
            if let plan = account.plan {
                Text(plan)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            AccountRefreshMark(state: account.state)
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
