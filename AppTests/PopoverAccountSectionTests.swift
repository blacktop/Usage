import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("Popover account sections")
@MainActor
struct PopoverAccountSectionTests {
    @Test("The overview keeps one-column dimensions and caps only oversized content")
    func overviewUsesOneColumnDimensions() {
        #expect(PopoverOverviewLayout.width == 340)
        #expect(PopoverOverviewLayout.maximumAccountAreaHeight >= 900)
        #expect(PopoverOverviewLayout.accountAreaHeight(measuredContentHeight: 480) == 480)
        #expect(
            PopoverOverviewLayout.accountAreaHeight(measuredContentHeight: 1_200)
                == PopoverOverviewLayout.maximumAccountAreaHeight
        )
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
        let presentation = ProviderUsagePresentation(section: section)
        #expect(presentation.accounts.count == 50)
        #expect(presentation.discoveredAccountCount == 0)
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

    @Test("Accounts share one provider presentation with meters grouped by window identity")
    func groupsMetersAcrossAccounts() throws {
        let weeklyID = WindowID(scope: .plan, slot: .primary, period: .weekly)
        let sparkID = WindowID(
            scope: .additional(feature: "gpt-5.3-codex-spark"),
            slot: .primary,
            period: .weekly
        )
        let reset = Date(timeIntervalSince1970: 2_000_000_000)
        let personal = try reportedState(
            label: "Codex",
            canonicalID: "personal",
            windows: [
                window(id: weeklyID, label: "Weekly", usedFraction: 0.04, resetsAt: reset),
                window(id: sparkID, label: "GPT-5.3-Codex-Spark", usedFraction: 0),
            ]
        )
        let team = try reportedState(
            label: "Codex TEAM",
            canonicalID: "team",
            windows: [
                window(id: weeklyID, label: "Weekly", usedFraction: 0.06, resetsAt: reset),
                window(id: sparkID, label: "GPT-5.3-Codex-Spark", usedFraction: 0),
            ]
        )

        let presentation = ProviderUsagePresentation(
            section: PopoverAccountSection(
                id: CodexProvider.id,
                displayName: "Codex",
                accounts: [personal, team],
                unrepresentedProfiles: []
            )
        )

        #expect(presentation.accounts.map(\.label) == ["Codex", "Codex TEAM"])
        #expect(presentation.accounts.map(\.colorIndex) == [0, 1])
        #expect(presentation.windowGroups.map(\.id) == [weeklyID, sparkID])
        #expect(presentation.windowGroups.map(\.label) == ["Weekly", "GPT-5.3-Codex-Spark"])
        #expect(presentation.windowGroups.map(\.meters.count) == [2, 2])
        #expect(
            presentation.windowGroups[0].meters.map(\.window.remainingFraction) == [0.96, 0.94]
        )
        #expect(
            presentation.windowGroups[0].meters.map(\.account.colorIndex) == [0, 1]
        )
    }

    @Test("A missing metric and an unsigned profile stay explicit without inventing empty bars")
    func keepsSparseMetricsAndConfiguredProfilesExplicit() throws {
        let weeklyID = WindowID(scope: .plan, slot: .primary, period: .weekly)
        let namedID = WindowID(
            scope: .additional(feature: "fable"),
            slot: .primary,
            period: .weekly
        )
        let personal = try reportedState(
            label: "Personal",
            canonicalID: "personal",
            windows: [
                window(id: weeklyID, label: "Weekly", usedFraction: 0.2),
                window(id: namedID, label: "Fable only", usedFraction: 0.4),
            ],
            credits: try CreditBalance(remaining: 8, granted: 10)
        )
        let team = try reportedState(
            label: "Team",
            canonicalID: "team",
            windows: [window(id: weeklyID, label: "Weekly", usedFraction: 0.3)]
        )
        let unsigned = ConfiguredProfileStatus(
            profile: try profile(label: "Offline", suffix: "codex-offline"),
            hasCredentialDocument: false
        )

        let presentation = ProviderUsagePresentation(
            section: PopoverAccountSection(
                id: CodexProvider.id,
                displayName: "Codex",
                accounts: [personal, team],
                unrepresentedProfiles: [unsigned]
            )
        )

        #expect(presentation.accounts.map(\.label) == ["Personal", "Team", "Offline"])
        #expect(presentation.accounts.map(\.colorIndex) == [0, 1, 2])
        #expect(presentation.windowGroups.map(\.meters.count) == [2, 1])
        #expect(presentation.windowGroups[1].meters.map(\.account.label) == ["Personal"])
        #expect(presentation.credits.map(\.account.label) == ["Personal"])
        #expect(presentation.accounts.last?.configuredProfile == unsigned)
        #expect(presentation.discoveredAccountCount == 2)
    }

    @Test("Only keychain-backed discovered accounts offer forced re-approval")
    func reapprovableAccountsFilterByBackend() throws {
        let keychainKey = AccountKey(
            providerID: CodexProvider.id,
            accountID: .canonical(provider: CodexProvider.id, canonicalID: "keychain")
        )
        let keychainState = AccountState(
            account: AccountProjection(
                key: keychainKey,
                slots: [CredentialSlotID(source: "keychain", opaqueID: "keychain")],
                displayName: "Claude DDB",
                availability: .active,
                credentialKinds: [.keychain]
            )
        )
        let fileState = AccountState(
            account: AccountProjection(
                key: AccountKey(
                    providerID: CodexProvider.id,
                    accountID: .canonical(provider: CodexProvider.id, canonicalID: "file")
                ),
                slots: [CredentialSlotID(source: "file", opaqueID: "file")],
                displayName: "Claude",
                availability: .active,
                credentialKinds: [.file]
            )
        )
        let presentation = ProviderUsagePresentation(
            section: PopoverAccountSection(
                id: CodexProvider.id,
                displayName: "Claude",
                accounts: [keychainState, fileState],
                unrepresentedProfiles: [
                    try ConfiguredProfileStatus(
                        profile: profile(label: "Pending", suffix: "pending"),
                        hasCredentialDocument: false
                    )
                ]
            )
        )

        #expect(presentation.reapprovableAccounts.map(\.key) == [keychainKey])
        #expect(presentation.reapprovableAccounts.first?.account.label == "Claude DDB")
    }

    @Test("Two windows sharing one label are told apart by their reported durations")
    func collidingWindowLabelsGainPeriods() throws {
        // The exact shape Codex reports for its Spark feature: two `.named` windows — kinds that
        // say nothing about the period — whose durations are five hours and one week.
        let sessionID = WindowID(
            scope: .additional(feature: "codex-spark"),
            slot: .primary,
            period: .session
        )
        let weeklyID = WindowID(
            scope: .additional(feature: "codex-spark"),
            slot: .secondary,
            period: .weekly
        )
        let planID = WindowID(scope: .plan, slot: .primary, period: .weekly)
        let state = try reportedState(
            label: "Codex",
            canonicalID: "personal",
            windows: [
                window(id: planID, label: "Weekly", usedFraction: 0.1),
                window(
                    id: sessionID, label: "GPT-5.3-Codex-Spark", usedFraction: 0.2,
                    kind: .named("GPT-5.3-Codex-Spark"), duration: .seconds(18_000)
                ),
                window(
                    id: weeklyID, label: "GPT-5.3-Codex-Spark", usedFraction: 0.3,
                    kind: .named("GPT-5.3-Codex-Spark"), duration: .seconds(604_800)
                ),
            ]
        )

        let presentation = ProviderUsagePresentation(
            section: PopoverAccountSection(
                id: CodexProvider.id,
                displayName: "Codex",
                accounts: [state],
                unrepresentedProfiles: []
            )
        )

        #expect(
            presentation.windowGroups.map(\.label) == [
                "Weekly",
                "GPT-5.3-Codex-Spark · 5h",
                "GPT-5.3-Codex-Spark · Weekly",
            ],
            "only the colliding label is qualified; the unique one is untouched"
        )
    }

    @Test("A partial cached report keeps its warning when a later refresh fails")
    func partialReportWarningSurvivesRefreshFailure() throws {
        let weeklyID = WindowID(scope: .plan, slot: .primary, period: .weekly)
        let state = try reportedState(
            label: "Personal",
            canonicalID: "personal",
            windows: [window(id: weeklyID, label: "Weekly", usedFraction: 0.2)],
            isPartial: true,
            lastError: .transportFailure()
        )
        let presentation = ProviderUsagePresentation(
            section: PopoverAccountSection(
                id: CodexProvider.id,
                displayName: "Codex",
                accounts: [state],
                unrepresentedProfiles: []
            )
        )
        let account = try #require(presentation.accounts.first)
        let issue = ProviderAccountIssuePresentation(account: account)

        #expect(issue.error == .transportFailure())
        #expect(issue.notice == "Some limits could not be read")
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

    private func reportedState(
        label: String,
        canonicalID: String,
        windows: [UsageWindow],
        credits: CreditBalance? = nil,
        isPartial: Bool = false,
        lastError: UsageError? = nil
    ) throws -> AccountState {
        let key = AccountKey(
            providerID: CodexProvider.id,
            accountID: .canonical(provider: CodexProvider.id, canonicalID: canonicalID)
        )
        let account = AccountProjection(
            key: key,
            slots: [CredentialSlotID(source: "codex.auth-json", opaqueID: label)],
            displayName: label,
            availability: .active
        )
        let report = try UsageReport(
            accountKey: key,
            plan: "pro",
            windows: windows,
            credits: credits,
            capturedAt: Date(timeIntervalSince1970: 1_900_000_000),
            isPartial: isPartial
        )
        return AccountState(account: account, report: report, lastError: lastError)
    }

    private func window(
        id: WindowID,
        label: String,
        usedFraction: Double,
        resetsAt: Date? = nil,
        kind: UsageWindow.Kind = .weekly,
        duration: Duration? = nil
    ) throws -> UsageWindow {
        try UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedFraction: usedFraction,
            resetsAt: resetsAt,
            duration: duration
        )
    }
}
