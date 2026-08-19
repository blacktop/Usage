import Foundation
import Testing
import UsageKit

@testable import Usage

/// Collects presented alerts so a test can assert on exactly what would have reached the user.
private actor CollectingPresenter: CredentialApprovalPresenter {
    private(set) var alerts: [CredentialApprovalAlert] = []
    private(set) var withdrawals: [AccountKey] = []

    func present(_ alert: CredentialApprovalAlert) async {
        alerts.append(alert)
    }

    func withdraw(for accountKey: AccountKey) async {
        withdrawals.append(accountKey)
    }
}

@Suite("Credential approval notifier")
struct CredentialApprovalNotifierTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let presenter = CollectingPresenter()
    private let notifier: CredentialApprovalNotifier

    init() {
        notifier = CredentialApprovalNotifier(presenter: presenter)
    }

    private func discover() async {
        await notifier.receive(
            .discovered(
                accounts: [ScriptedProvider.account],
                provider: ScriptedProvider.id,
                at: start
            )
        )
    }

    private func fail(with error: UsageError) async {
        await notifier.receive(.failed(error: error, key: ScriptedProvider.accountKey, at: start))
    }

    private func succeed() async throws {
        let report = try UsageReport(
            accountKey: ScriptedProvider.accountKey,
            plan: "scripted",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: 0.5
                )
            ],
            capturedAt: start
        )
        await notifier.receive(.succeeded(report: report, at: start))
    }

    @Test("The first approval-required failure alerts once, with the account's display name")
    func firstFailureAlerts() async {
        await discover()
        await fail(with: .interactionForbidden())
        await fail(with: .interactionForbidden())

        let alerts = await presenter.alerts
        #expect(
            alerts == [
                CredentialApprovalAlert(
                    accountKey: ScriptedProvider.accountKey,
                    accountName: "scripted@example.com"
                )
            ]
        )
    }

    @Test("A success clears the flag, so a later rotation alerts again")
    func successRearmsAlert() async throws {
        await discover()
        await fail(with: .interactionForbidden())
        try await succeed()
        await fail(with: .interactionForbidden())

        #expect(await presenter.alerts.count == 2)
        #expect(await presenter.withdrawals == [ScriptedProvider.accountKey])
    }

    @Test("A success with no outstanding alert withdraws nothing")
    func successWithoutAlertWithdrawsNothing() async throws {
        await discover()
        try await succeed()

        #expect(await presenter.withdrawals.isEmpty)
    }

    @Test("Failures that approval cannot repair never alert")
    func otherFailuresStaySilent() async {
        await discover()
        await fail(with: .transportFailure())
        await fail(with: .credentialUnavailable(kind: .keychain))
        await fail(with: .from(HTTPResponse(status: 401)))

        #expect(await presenter.alerts.isEmpty)
    }

    @Test("An account that was never discovered still alerts, named after its provider")
    func undiscoveredAccountFallsBackToProviderName() async {
        await fail(with: .interactionForbidden())

        let alerts = await presenter.alerts
        #expect(alerts.count == 1)
        #expect(alerts.first?.accountName == ScriptedProvider.id.rawValue)
    }

    @Test("Rediscovery without the account drops its flag; an empty discovery retires nothing")
    func retirementFollowsDiscovery() async {
        await discover()
        await fail(with: .interactionForbidden())

        await notifier.receive(
            .discovered(accounts: [], provider: ScriptedProvider.id, at: start)
        )
        await fail(with: .interactionForbidden())
        #expect(await presenter.alerts.count == 1)

        let replacement = ProviderAccount(
            key: AccountKey(
                providerID: ScriptedProvider.id,
                accountID: .canonical(provider: ScriptedProvider.id, canonicalID: "scripted-2")
            ),
            slot: CredentialSlotID(source: "scripted", opaqueID: "scripted-2"),
            locator: CredentialLocator(kind: .file, identifier: "/dev/null"),
            displayName: "replacement@example.com",
            availability: .active
        )
        await notifier.receive(
            .discovered(accounts: [replacement], provider: ScriptedProvider.id, at: start)
        )
        // Retirement withdrew the outstanding notification: the retired account can never emit
        // the success that would otherwise clear it.
        #expect(await presenter.withdrawals == [ScriptedProvider.accountKey])
        await fail(with: .interactionForbidden())
        #expect(await presenter.alerts.count == 2)
        // Retirement dropped the cached display name along with the flag, so the re-alert falls
        // back to the provider's identifier.
        #expect(await presenter.alerts.last?.accountName == ScriptedProvider.id.rawValue)
    }
}
