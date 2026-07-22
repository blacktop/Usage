import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("Credits row formatting")
@MainActor
struct CreditsRowTests {
    private func monetary(currency: String) throws -> CreditBalance {
        try CreditBalance(remaining: Decimal(35), granted: Decimal(50), currency: currency)
    }

    private func providerDefined() throws -> CreditBalance {
        try CreditBalance(remaining: Decimal(35), granted: Decimal(50))
    }

    @Test("A balance in a provider-defined unit renders as bare numbers")
    func providerDefinedUnitRendersBareNumbers() throws {
        #expect(CreditBalanceText.text(for: try providerDefined()) == "35 of 50")
    }

    @Test("A monetary balance is never rendered as if it were a unit-less count")
    func monetaryBalanceIsDistinguishable() throws {
        let money = CreditBalanceText.text(for: try monetary(currency: "USD"))
        #expect(money != CreditBalanceText.text(for: try providerDefined()))
        #expect(money.contains(Decimal(35).formatted(.currency(code: "USD"))))
        #expect(money.contains(Decimal(50).formatted(.currency(code: "USD"))))
    }

    @Test("Two balances differing only in currency render differently")
    func currencyIsNotDropped() throws {
        #expect(
            CreditBalanceText.text(for: try monetary(currency: "USD"))
                != CreditBalanceText.text(for: try monetary(currency: "JPY"))
        )
    }

    @Test("A monetary balance with no granted total still carries its currency")
    func remainingOnlyBalanceKeepsItsCurrency() throws {
        let credits = try CreditBalance(remaining: Decimal(7), currency: "EUR")
        #expect(
            CreditBalanceText.text(for: credits)
                == Decimal(7).formatted(.currency(code: "EUR"))
        )
        #expect(CreditBalanceText.text(for: credits) != "7")
    }

    @Test("A fractional balance keeps its fraction in both unit systems")
    func fractionalAmountsAreReadable() throws {
        let value = try #require(Decimal(string: "12.5"))
        #expect(CreditBalanceText.text(for: try CreditBalance(remaining: value)) == "12.5")
        let money = try CreditBalance(remaining: value, currency: "USD")
        #expect(CreditBalanceText.text(for: money) == value.formatted(.currency(code: "USD")))
    }
}
