import Foundation
import Testing

@testable import UsageKit

@Suite("Window identity")
struct WindowIDTests {
    @Test("A named limit's primary and secondary windows get distinct identifiers")
    func namedLimitSlotsDoNotCollide() {
        let scope = WindowID.Scope.additional(feature: "gpt-5.3-codex-spark")
        let primary = WindowID(scope: scope, slot: .primary, period: .weekly)
        let secondary = WindowID(scope: scope, slot: .secondary, period: .weekly)
        #expect(primary != secondary)
        #expect(primary.rawValue == "additional:gpt-5.3-codex-spark:primary:weekly")
        #expect(secondary.rawValue == "additional:gpt-5.3-codex-spark:secondary:weekly")
    }

    @Test("Plan windows and additional windows occupy separate namespaces")
    func planAndAdditionalScopesAreSeparate() {
        let plan = WindowID(scope: .plan, slot: .primary, period: .weekly)
        let additional = WindowID(
            scope: .additional(feature: "plan"),
            slot: .primary,
            period: .weekly
        )
        #expect(plan != additional)
        #expect(plan.rawValue == "plan:primary:weekly")
    }

    @Test("Identity is independent of the display label")
    func identityIgnoresLabel() throws {
        let id = WindowID(scope: .plan, slot: .primary, period: .session)
        let first = try UsageWindow(id: id, kind: .session, label: "5h limit", usedFraction: 0.1)
        let second = try UsageWindow(id: id, kind: .session, label: "Session", usedFraction: 0.1)
        #expect(first.id == second.id)
    }

    @Test("A feature name cannot inject a component separator")
    func featureNamesAreEscaped() {
        let injected = WindowID(
            scope: .additional(feature: "a:primary:weekly"),
            slot: .secondary,
            period: .monthly
        )
        let plain = WindowID(
            scope: .additional(feature: "a"),
            slot: .primary,
            period: .weekly
        )
        #expect(injected != plain)
        #expect(injected.rawValue == "additional:a%3Aprimary%3Aweekly:secondary:monthly")
    }

    @Test("Escaping preserves case and punctuation rather than normalising them away")
    func escapingIsLossless() {
        let upper = WindowID(scope: .additional(feature: "Spark"), slot: .primary, period: .daily)
        let lower = WindowID(scope: .additional(feature: "spark"), slot: .primary, period: .daily)
        #expect(upper != lower)
        let spaced = WindowID(
            scope: .additional(feature: "premium requests"),
            slot: .primary,
            period: .monthly
        )
        #expect(spaced.rawValue == "additional:premium%20requests:primary:monthly")
    }

    @Test("Rolling periods carry their span, so two rolling windows stay distinct")
    func rollingPeriodsAreDistinct() {
        let fiveHours = WindowID(scope: .plan, slot: .primary, period: .rolling(seconds: 18_000))
        let oneDay = WindowID(scope: .plan, slot: .primary, period: .rolling(seconds: 86_400))
        #expect(fiveHours != oneDay)
        #expect(fiveHours.rawValue == "plan:primary:rolling-18000s")
    }

    @Test("An empty raw identifier is rejected on construction and on decoding")
    func emptyIdentifierIsRejected() {
        #expect(WindowID(rawValue: "") == nil)
        #expect(throws: DecodingError.self) {
            try UsageJSON.decoder().decode(WindowID.self, from: Data("\"\"".utf8))
        }
    }

    @Test("A report rejects two windows sharing one identifier")
    func duplicateWindowIdentifiersAreRejected() throws {
        let id = WindowID(scope: .plan, slot: .primary, period: .weekly)
        let windows = [
            try UsageWindow(id: id, kind: .weekly, label: "A", usedFraction: 0.1),
            try UsageWindow(id: id, kind: .weekly, label: "B", usedFraction: 0.2),
        ]
        #expect(throws: UsageError.invalidValue(field: "windows.id", rule: .unique)) {
            try UsageReport(
                accountKey: Fixtures.canonicalKey("alpha"),
                plan: nil,
                windows: windows,
                capturedAt: Fixtures.capturedAt
            )
        }
    }
}
