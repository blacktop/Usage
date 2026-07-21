import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("Popover account sections")
@MainActor
struct PopoverAccountSectionTests {
    @Test("The overview reserves a full viewport and one column for every shipped provider")
    func overviewFitsEveryProviderAtOnce() {
        #expect(PopoverOverviewLayout.accountAreaHeight >= 600)
        #expect(PopoverOverviewLayout.width(forProviderCount: 0) == 620)
        #expect(PopoverOverviewLayout.width(forProviderCount: 1) == 620)
        #expect(PopoverOverviewLayout.width(forProviderCount: 2) == 920)
        #expect(PopoverOverviewLayout.width(forProviderCount: 3) == 1_220)
    }

    @Test("Every configured Codex root stays visible before it has a sign-in file")
    func keepsEveryConfiguredRootVisible() throws {
        let profiles = try (0..<50).map { index in
            ConfiguredProfileStatus(
                profile: try profile(label: "Codex \(index)", suffix: "codex-\(index)"),
                hasCredentialDocument: false
            )
        }

        let sections = PopoverAccountSection.sections(
            accounts: [],
            profiles: profiles,
            registry: ProviderRegistry(providers: [CodexProvider()])
        )

        let section = try #require(sections.first)
        #expect(sections.count == 1)
        #expect(section.id == CodexProvider.id)
        #expect(section.visibleRowCount == 50)
        #expect(section.accounts.isEmpty)
        #expect(section.unrepresentedProfiles.map(\.id) == profiles.map(\.id))
    }

    @Test("A discovered account replaces only the configured profile it represents")
    func discoveredAccountReplacesItsProfilePlaceholder() throws {
        let personal = try profile(label: "Personal", suffix: "codex")
        let team = try profile(label: "Team", suffix: "codex-team")
        let state = accountState(label: "Personal", profileRootIDs: [personal.id])

        let section = try #require(
            PopoverAccountSection.sections(
                accounts: [state],
                profiles: [
                    ConfiguredProfileStatus(
                        profile: personal,
                        hasCredentialDocument: true
                    ),
                    ConfiguredProfileStatus(profile: team, hasCredentialDocument: false),
                ],
                registry: ProviderRegistry(providers: [CodexProvider()])
            ).first
        )

        #expect(section.visibleRowCount == 2)
        #expect(section.accounts.map(\.account.displayName) == ["Personal"])
        #expect(section.unrepresentedProfiles.map(\.profile.label) == ["Team"])
    }

    @Test("Canonical reconciliation represents every root without duplicating the account card")
    func reconciledAccountRepresentsAllOfItsRoots() throws {
        let personal = try profile(label: "Personal", suffix: "codex")
        let team = try profile(label: "Team", suffix: "codex-team")
        let state = accountState(
            label: "Personal",
            profileRootIDs: [personal.id, team.id]
        )

        let section = try #require(
            PopoverAccountSection.sections(
                accounts: [state],
                profiles: [
                    ConfiguredProfileStatus(profile: personal, hasCredentialDocument: true),
                    ConfiguredProfileStatus(profile: team, hasCredentialDocument: true),
                ],
                registry: ProviderRegistry(providers: [CodexProvider()])
            ).first
        )

        #expect(section.accounts.count == 1)
        #expect(section.unrepresentedProfiles.isEmpty)
        #expect(section.visibleRowCount == 1)
    }

    private func profile(label: String, suffix: String) throws -> ProfileRoot {
        try ProfileRoot(
            providerID: CodexProvider.id,
            label: label,
            configurationDirectoryPath: "/Users/fixture/.\(suffix)"
        )
    }

    private func accountState(
        label: String,
        profileRootIDs: [ProfileRootID]
    ) -> AccountState {
        let key = AccountKey(
            providerID: CodexProvider.id,
            accountID: .canonical(provider: CodexProvider.id, canonicalID: "account")
        )
        return AccountState(
            account: AccountProjection(
                key: key,
                slots: [CredentialSlotID(source: "codex.auth-json", opaqueID: label)],
                profileRootIDs: profileRootIDs,
                displayName: label,
                availability: .active
            )
        )
    }
}
