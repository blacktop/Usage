import Foundation
import Testing

@testable import UsageKit

@Suite("Provider mapper validation")
struct MapperValidationTests {
    private let id = WindowID(scope: .plan, slot: .primary, period: .weekly)

    private func window(_ fraction: Double, detail: UsageDetail? = nil) throws -> UsageWindow {
        try UsageWindow(
            id: id,
            kind: .weekly,
            label: "Weekly",
            usedFraction: fraction,
            detail: detail
        )
    }

    @Test("A negative fraction is rejected")
    func negativeFractionIsRejected() {
        #expect(throws: UsageError.invalidValue(field: "usedFraction", rule: .nonNegative)) {
            try window(-0.01)
        }
    }

    @Test(
        "NaN and both infinities are rejected",
        arguments: [
            Double.nan, .infinity, -.infinity, .signalingNaN,
        ])
    func nonFiniteFractionsAreRejected(fraction: Double) {
        #expect(throws: UsageError.invalidValue(field: "usedFraction", rule: .finite)) {
            try window(fraction)
        }
    }

    @Test("An over-quota fraction is preserved, not clamped")
    func overQuotaFractionIsPreserved() throws {
        let window = try window(1.4)
        #expect(window.usedFraction == 1.4)
        #expect(window.renderFraction == 1.0)
    }

    @Test("Clamping is a render-time concern only")
    func renderFractionClampsBothEnds() throws {
        #expect(try window(0).renderFraction == 0)
        #expect(try window(0.5).renderFraction == 0.5)
        #expect(try window(12).renderFraction == 1)
    }

    @Test("Remaining capacity inverts usage and floors exhausted or over-quota windows at zero")
    func remainingFractionInvertsUsage() throws {
        #expect(try window(0).remainingFraction == 1)
        #expect(try window(0.25).remainingFraction == 0.75)
        #expect(try window(1).remainingFraction == 0)
        #expect(try window(1.4).remainingFraction == 0)
    }

    @Test("Negative counts are rejected on either side of the ratio")
    func negativeCountsAreRejected() {
        #expect(throws: UsageError.invalidValue(field: "detail.limit", rule: .nonNegative)) {
            try window(0.5, detail: .count(used: 5, limit: -1))
        }
        #expect(throws: UsageError.invalidValue(field: "detail.used", rule: .nonNegative)) {
            try window(0.5, detail: .count(used: -5, limit: 100))
        }
    }

    @Test("Consumption against a zero allowance is rejected as inconsistent")
    func inconsistentCountLimitIsRejected() {
        #expect(throws: UsageError.invalidValue(field: "detail.used", rule: .consistent)) {
            try window(0.5, detail: .count(used: 3, limit: 0))
        }
    }

    @Test("A count above its limit is accepted, because over-quota is real")
    func countAboveLimitIsAccepted() throws {
        let window = try window(1.2, detail: .count(used: 120, limit: 100))
        #expect(window.detail == .count(used: 120, limit: 100))
    }

    @Test("A zero-usage, zero-limit window is accepted")
    func zeroOverZeroIsAccepted() throws {
        let window = try window(0, detail: .count(used: 0, limit: 0))
        #expect(window.detail == .count(used: 0, limit: 0))
    }

    @Test("Negative money is rejected")
    func negativeMoneyIsRejected() {
        #expect(throws: UsageError.invalidValue(field: "detail.spent", rule: .nonNegative)) {
            try window(
                0.5, detail: .money(spent: Decimal(-1), budget: Decimal(50), currency: "USD"))
        }
        #expect(throws: UsageError.invalidValue(field: "detail.budget", rule: .nonNegative)) {
            try window(
                0.5, detail: .money(spent: Decimal(1), budget: Decimal(-50), currency: "USD"))
        }
    }

    @Test("A non-numeric decimal is rejected")
    func nonNumericMoneyIsRejected() {
        #expect(throws: UsageError.invalidValue(field: "detail.spent", rule: .finite)) {
            try window(0.5, detail: .money(spent: .nan, budget: Decimal(50), currency: "USD"))
        }
    }

    @Test("Spend against a zero budget is rejected as inconsistent")
    func inconsistentBudgetIsRejected() {
        #expect(throws: UsageError.invalidValue(field: "detail.spent", rule: .consistent)) {
            try window(0.5, detail: .money(spent: Decimal(3), budget: Decimal(0), currency: "USD"))
        }
    }

    @Test("A malformed currency code is rejected", arguments: ["usd", "DOLLARS", "US", "US1", ""])
    func malformedCurrencyIsRejected(code: String) {
        #expect(throws: UsageError.invalidValue(field: "detail.currency", rule: .currencyCode)) {
            try window(0.5, detail: .money(spent: Decimal(1), budget: Decimal(50), currency: code))
        }
    }

    @Test("Credit balances validate the same way")
    func creditBalanceIsValidated() {
        #expect(throws: UsageError.invalidValue(field: "credits.remaining", rule: .nonNegative)) {
            try CreditBalance(remaining: Decimal(-1))
        }
        #expect(throws: UsageError.invalidValue(field: "credits.granted", rule: .nonNegative)) {
            try CreditBalance(remaining: Decimal(1), granted: Decimal(-1))
        }
        #expect(throws: UsageError.invalidValue(field: "credits.currency", rule: .currencyCode)) {
            try CreditBalance(remaining: Decimal(1), currency: "usd")
        }
    }

    @Test("Decoding an in-memory window re-runs the same validation")
    func decodingRevalidates() throws {
        let valid = try window(0.5)
        var object = try #require(
            try JSONSerialization.jsonObject(
                with: UsageJSON.encoder().encode(valid)
            ) as? [String: Any]
        )
        object["usedFraction"] = -1.0
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: UsageError.invalidValue(field: "usedFraction", rule: .nonNegative)) {
            try UsageJSON.decoder().decode(UsageWindow.self, from: data)
        }
    }
}
