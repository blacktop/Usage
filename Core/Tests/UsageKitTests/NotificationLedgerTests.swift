import Foundation
import Testing

@testable import UsageKit

@Suite("Usage notification ledger")
struct NotificationLedgerTests {
    private let provider = ProviderID("codex")
    private let weeklyID = WindowID(scope: .plan, slot: .primary, period: .weekly)

    @Test("Persisted state prevents a threshold replay after relaunch")
    func relaunchDoesNotReplayCrossing() throws {
        var firstRun = UsageNotificationLedger()
        let baseline = try report(account: canonical("personal"), used: 0.79, capturedAt: 100)
        let crossing = try report(account: canonical("personal"), used: 0.82, capturedAt: 200)
        #expect(firstRun.evaluate(baseline, resolvingWith: IdentityReconciler()).isEmpty)
        #expect(
            firstRun.evaluate(crossing, resolvingWith: IdentityReconciler()).map(\.kind)
                == [.threshold(.warning)]
        )

        let encoded = try UsageJSON.encoder().encode(firstRun.state)
        let decoded = try UsageJSON.decoder().decode(UsageNotificationStateV1.self, from: encoded)
        var relaunched = try UsageNotificationLedger(
            state: decoded,
            reconciler: IdentityReconciler()
        )

        #expect(relaunched.evaluate(crossing, resolvingWith: IdentityReconciler()).isEmpty)
    }

    @Test("The versioned notification state has a stable token-free JSON shape")
    func notificationStateGolden() throws {
        let state = UsageNotificationStateV1(records: [
            record(account: canonical("personal"), used: 0.82, capturedAt: 200)
        ])

        let encoded = try UsageJSON.encoder().encode(state)

        #expect(
            String(decoding: encoded, as: UTF8.self)
                == """
                {"records":[{"accountID":"\(canonical("personal").accountID.rawValue)",\
                "capturedAt":200,"providerID":"codex","usedFraction":0.82,\
                "windowID":"plan:primary:weekly"}],"schemaVersion":1}
                """
        )
    }

    @Test("A persisted reset cycle does not replay after relaunch")
    func relaunchDoesNotReplayReset() throws {
        let account = canonical("personal")
        let oldReset: Int64 = 1_000
        let newReset: Int64 = 2_000
        var firstRun = UsageNotificationLedger()
        _ = firstRun.evaluate(
            try report(account: account, used: 0.90, resetsAt: oldReset, capturedAt: 900),
            resolvingWith: IdentityReconciler()
        )
        let resetReport = try report(
            account: account,
            used: 0.05,
            resetsAt: newReset,
            capturedAt: 1_001
        )
        #expect(
            firstRun.evaluate(resetReport, resolvingWith: IdentityReconciler()).map(\.kind)
                == [.reset]
        )
        var relaunched = try UsageNotificationLedger(
            state: firstRun.state,
            reconciler: IdentityReconciler()
        )

        #expect(relaunched.evaluate(resetReport, resolvingWith: IdentityReconciler()).isEmpty)
    }

    @Test("Two accounts crossing the same threshold notify independently")
    func accountsAreIndependent() throws {
        var ledger = UsageNotificationLedger()
        let reconciler = IdentityReconciler()
        let personal = canonical("personal")
        let team = canonical("team")
        _ = ledger.evaluate(
            try report(account: personal, used: 0.79, capturedAt: 100),
            resolvingWith: reconciler
        )
        _ = ledger.evaluate(
            try report(account: team, used: 0.79, capturedAt: 100),
            resolvingWith: reconciler
        )

        let personalEvents = ledger.evaluate(
            try report(account: personal, used: 0.81, capturedAt: 200),
            resolvingWith: reconciler
        )
        let teamEvents = ledger.evaluate(
            try report(account: team, used: 0.83, capturedAt: 200),
            resolvingWith: reconciler
        )

        #expect(personalEvents.map(\.accountKey) == [personal])
        #expect(teamEvents.map(\.accountKey) == [team])
    }

    @Test("A persisted fallback baseline follows its canonical promotion")
    func aliasPromotionKeepsDedupeState() throws {
        let slot = CredentialSlotID(source: "codex.auth-json", opaqueID: "personal")
        let fallback = AccountKey(
            providerID: provider,
            accountID: .credentialSlot(provider: provider, slot: slot)
        )
        let canonical = canonical("personal")
        let state = UsageNotificationStateV1(records: [
            record(account: fallback, used: 0.82, capturedAt: 100)
        ])
        var reconciler = IdentityReconciler()
        #expect(
            reconciler.observe(
                fallback: fallback,
                canonical: canonical,
                at: Date(timeIntervalSince1970: 150)
            ) == .recorded
        )
        var ledger = try UsageNotificationLedger(state: state, reconciler: reconciler)

        let events = ledger.evaluate(
            try report(account: canonical, used: 0.85, capturedAt: 200),
            resolvingWith: reconciler
        )

        #expect(events.isEmpty)
        #expect(ledger.state.records.map(\.accountID) == [canonical.accountID.rawValue])
    }

    @Test("An older report cannot rewind persisted notification state")
    func staleReportIsIgnored() throws {
        var ledger = UsageNotificationLedger()
        let account = canonical("personal")
        _ = ledger.evaluate(
            try report(account: account, used: 0.82, capturedAt: 200),
            resolvingWith: IdentityReconciler()
        )

        let events = ledger.evaluate(
            try report(account: account, used: 0.10, capturedAt: 100),
            resolvingWith: IdentityReconciler()
        )

        #expect(events.isEmpty)
        #expect(ledger.state.records.first?.usedFraction == 0.82)
    }

    private func canonical(_ value: String) -> AccountKey {
        AccountKey(
            providerID: provider,
            accountID: .canonical(provider: provider, canonicalID: value)
        )
    }

    private func report(
        account: AccountKey,
        used: Double,
        resetsAt: Int64? = nil,
        capturedAt: Int64
    ) throws -> UsageReport {
        try UsageReport(
            accountKey: account,
            plan: "pro",
            windows: [
                UsageWindow(
                    id: weeklyID,
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: used,
                    resetsAt: resetsAt.map(EpochSeconds.date)
                )
            ],
            capturedAt: EpochSeconds.date(capturedAt)
        )
    }

    private func record(
        account: AccountKey,
        used: Double,
        capturedAt: Int64
    ) -> UsageNotificationStateV1.Record {
        UsageNotificationStateV1.Record(
            providerID: account.providerID.rawValue,
            accountID: account.accountID.rawValue,
            windowID: weeklyID.rawValue,
            usedFraction: used,
            resetsAt: nil,
            capturedAt: capturedAt
        )
    }
}
