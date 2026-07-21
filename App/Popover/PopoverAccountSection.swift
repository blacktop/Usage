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

struct PopoverAccountList: View {
    private static let topID = "provider-account-list-top"

    let sections: [PopoverAccountSection]
    let onRetry: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Color.clear
                    .frame(height: 0)
                    .id(Self.topID)

                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            ProviderAccountRows(section: section, onRetry: onRetry)
                        } header: {
                            ProviderSectionHeader(section: section)
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .scrollIndicators(.hidden)
            .frame(minHeight: 76, maxHeight: 420)
            .overlay {
                if sections.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "person.crop.circle.badge.questionmark",
                        description: Text("Add a provider config folder in Settings.")
                    )
                }
            }
            .onAppear { proxy.scrollTo(Self.topID, anchor: .top) }
        }
        .accessibilityIdentifier("provider-account-list")
    }
}

private struct ProviderSectionHeader: View {
    let section: PopoverAccountSection

    var body: some View {
        Text(section.displayName)
            .font(.caption.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
    }
}

private struct ProviderAccountRows: View {
    let section: PopoverAccountSection
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(section.accounts) { state in
                AccountCard(state: state, onRetry: onRetry)
            }

            ForEach(section.unrepresentedProfiles) { profile in
                UnrepresentedProfileRow(status: profile)
            }
        }
    }
}

private struct UnrepresentedProfileRow: View {
    let status: ConfiguredProfileStatus

    private var profile: ProfileRoot { status.profile }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(status.hasCredentialDocument ? .orange : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.label)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.primary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configured-profile-\(profile.id.rawValue)")
    }

    private var message: String {
        status.hasCredentialDocument
            ? "No usable account found"
            : "Not signed in"
    }
}
