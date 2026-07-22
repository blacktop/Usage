import Foundation
import Testing

@testable import UsageKit

@Suite("Usage notification evaluator")
struct NotificationEvaluatorTests {
    private let account = AccountKey(
        providerID: ProviderID("codex"),
        accountID: .canonical(provider: ProviderID("codex"), canonicalID: "personal")
    )
    private let otherAccount = AccountKey(
        providerID: ProviderID("codex"),
        accountID: .canonical(provider: ProviderID("codex"), canonicalID: "team")
    )
    private let weeklyID = WindowID(scope: .plan, slot: .primary, period: .weekly)

    @Test("A first observation establishes a baseline without notifying")
    func firstObservationIsSilent() throws {
        let current = try report(used: 0.99)

        #expect(UsageNotificationEvaluator.evaluate(previous: nil, current: current).isEmpty)
    }

    @Test("Crossing warning and critical thresholds emits each boundary once")
    func emitsEveryCrossedThreshold() throws {
        let previous = try report(used: 0.79)
        let current = try report(used: 0.96, capturedAt: previous.capturedAt.addingTimeInterval(60))

        let events = UsageNotificationEvaluator.evaluate(previous: previous, current: current)

        #expect(events.map(\.kind) == [.threshold(.warning), .threshold(.critical)])
        #expect(events.allSatisfy { $0.accountKey == account && $0.windowID == weeklyID })
    }

    @Test("Remaining above a crossed threshold does not notify again")
    func doesNotRepeatWhileAboveThreshold() throws {
        let previous = try report(used: 0.96)
        let current = try report(used: 0.98, capturedAt: previous.capturedAt.addingTimeInterval(60))

        #expect(UsageNotificationEvaluator.evaluate(previous: previous, current: current).isEmpty)
    }

    @Test("Falling below a threshold re-arms its next crossing")
    func rearmsAfterRecovery() throws {
        let below = try report(used: 0.70)
        let crossing = try report(used: 0.82, capturedAt: below.capturedAt.addingTimeInterval(60))

        #expect(
            UsageNotificationEvaluator.evaluate(previous: below, current: crossing).map(\.kind)
                == [.threshold(.warning)]
        )
    }

    @Test("Threshold state is independent for accounts sharing a window identity")
    func accountsDoNotShareThresholdState() throws {
        let previous = try report(used: 0.79)
        let current = try report(
            account: otherAccount,
            used: 0.90,
            capturedAt: previous.capturedAt.addingTimeInterval(60)
        )

        #expect(UsageNotificationEvaluator.evaluate(previous: previous, current: current).isEmpty)
    }

    @Test("A provider-supplied next reset notifies after the prior reset passes")
    func emitsProvenReset() throws {
        let oldReset = Date(timeIntervalSince1970: 2_000_000_000)
        let previous = try report(used: 0.92, resetsAt: oldReset)
        let newReset = oldReset.addingTimeInterval(7 * 24 * 60 * 60)
        let current = try report(
            used: 0.02,
            resetsAt: newReset,
            capturedAt: oldReset.addingTimeInterval(30)
        )

        let events = UsageNotificationEvaluator.evaluate(previous: previous, current: current)

        #expect(events.map(\.kind) == [.reset])
        #expect(events.first?.resetsAt == newReset)
    }

    @Test("A changed future estimate is not mistaken for a completed reset")
    func ignoresFutureResetAdjustment() throws {
        let oldReset = Date(timeIntervalSince1970: 2_000_000_000)
        let previous = try report(used: 0.30, resetsAt: oldReset)
        let current = try report(
            used: 0.31,
            resetsAt: oldReset.addingTimeInterval(60),
            capturedAt: oldReset.addingTimeInterval(-60)
        )

        #expect(UsageNotificationEvaluator.evaluate(previous: previous, current: current).isEmpty)
    }

    @Test("A missing reset date never produces an inferred reset")
    func nilResetNeverNotifies() throws {
        let previous = try report(used: 0.90, resetsAt: nil)
        let current = try report(
            used: 0.05,
            resetsAt: nil,
            capturedAt: previous.capturedAt.addingTimeInterval(60)
        )

        #expect(UsageNotificationEvaluator.evaluate(previous: previous, current: current).isEmpty)
    }

    @Test("A newly appearing window establishes its own baseline")
    func newWindowIsSilent() throws {
        let previous = try report(windows: [])
        let current = try report(used: 0.99, capturedAt: previous.capturedAt.addingTimeInterval(60))

        #expect(UsageNotificationEvaluator.evaluate(previous: previous, current: current).isEmpty)
    }

    private func report(
        account: AccountKey? = nil,
        used: Double,
        resetsAt: Date? = nil,
        capturedAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) throws -> UsageReport {
        try report(
            account: account,
            windows: [window(used: used, resetsAt: resetsAt)],
            capturedAt: capturedAt
        )
    }

    private func report(
        account: AccountKey? = nil,
        windows: [UsageWindow],
        capturedAt: Date = Date(timeIntervalSince1970: 1_900_000_000)
    ) throws -> UsageReport {
        try UsageReport(
            accountKey: account ?? self.account,
            plan: "pro",
            windows: windows,
            capturedAt: capturedAt
        )
    }

    private func window(used: Double, resetsAt: Date?) throws -> UsageWindow {
        try UsageWindow(
            id: weeklyID,
            kind: .weekly,
            label: "Weekly",
            usedFraction: used,
            resetsAt: resetsAt
        )
    }
}
