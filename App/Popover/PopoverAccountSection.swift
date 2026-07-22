import SwiftUI
import UsageKit

/// One provider's visible popover rows.
///
/// A configured profile stays visible until discovery represents it. This is intentionally a UI
/// projection rather than a fake `ProviderAccount`: a missing credential must not enter the refresh
/// schedule or replace a canonical account whose last good report is still cached.
struct PopoverAccountSection: Identifiable {
    let id: ProviderID
    let displayName: String
    let accounts: [AccountState]
    let unrepresentedProfiles: [ConfiguredProfileStatus]

    var visibleRowCount: Int { accounts.count + unrepresentedProfiles.count }

    static func sections(
        accounts: [AccountState],
        profiles: [ConfiguredProfileStatus],
        registry: ProviderRegistry
    ) -> [PopoverAccountSection] {
        var providerIDs = registry.providerIDs
        for id in profiles.map(\.profile.providerID) + accounts.map(\.account.key.providerID)
        where !providerIDs.contains(id) {
            providerIDs.append(id)
        }

        return providerIDs.compactMap { providerID in
            let providerAccounts = accounts.filter { $0.account.key.providerID == providerID }
            let representedRoots = Set(providerAccounts.flatMap(\.account.profileRootIDs))
            let unmatchedProfiles = profiles.filter {
                $0.profile.providerID == providerID && !representedRoots.contains($0.id)
            }
            guard !providerAccounts.isEmpty || !unmatchedProfiles.isEmpty else { return nil }
            return PopoverAccountSection(
                id: providerID,
                displayName: registry.provider(for: providerID)?.displayName
                    ?? providerID.rawValue.capitalized,
                accounts: providerAccounts,
                unrepresentedProfiles: unmatchedProfiles
            )
        }
    }
}

enum PopoverOverviewLayout {
    static let width: CGFloat = 620
    static let maximumAccountAreaHeight: CGFloat = 900

    static func accountAreaHeight(measuredContentHeight: CGFloat) -> CGFloat {
        min(max(measuredContentHeight, 1), maximumAccountAreaHeight)
    }
}

struct PopoverAccountList: View {
    let sections: [PopoverAccountSection]
    let onRetry: (AccountKey, Bool) -> Void

    @State private var measuredContentHeight = PopoverOverviewLayout.maximumAccountAreaHeight

    var body: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(
                    "No accounts yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Add a provider config folder in Settings.")
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(sections) { section in
                            ProviderUsageCard(section: section, onRetry: onRetry)
                        }
                    }
                    .padding(.bottom, 2)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { height in
                        measuredContentHeight = height
                    }
                }
                .frame(
                    height: PopoverOverviewLayout.accountAreaHeight(
                        measuredContentHeight: measuredContentHeight
                    )
                )
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .accessibilityIdentifier("provider-account-list")
    }
}
