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
    let sections: [PopoverAccountSection]
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 10) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(sections) { section in
                        ProviderAccountSection(section: section, onRetry: onRetry)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 90, maxHeight: 560)
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView(
                    "No accounts yet",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Add a provider config folder in Settings.")
                )
            }
        }
        .accessibilityIdentifier("provider-account-list")
    }
}

private struct ProviderAccountSection: View {
    let section: PopoverAccountSection
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(section.displayName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(section.visibleRowCount, format: .number)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("\(section.visibleRowCount) visible rows")
            }

            ForEach(section.accounts) { state in
                AccountCard(state: state, onRetry: onRetry)
            }

            ForEach(section.unrepresentedProfiles) { profile in
                UnrepresentedProfileCard(status: profile)
            }
        }
    }
}

private struct UnrepresentedProfileCard: View {
    let status: ConfiguredProfileStatus

    private var profile: ProfileRoot { status.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(profile.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Label(message, systemImage: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
            Text(profile.configurationDirectoryPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.orange.opacity(0.08)), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("configured-profile-\(profile.id.rawValue)")
    }

    private var message: String {
        status.hasCredentialDocument
            ? "No usable account was discovered in this folder."
            : "No sign-in file here yet."
    }
}
