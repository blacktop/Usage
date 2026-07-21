import Foundation

/// A prepaid or granted balance that is not expressed as a window.
///
/// Providers with credit systems land here rather than adding a field to `UsageReport`.
public struct CreditBalance: Sendable, Hashable, Codable {
    public let remaining: Decimal
    public let granted: Decimal?
    /// ISO-4217 code, or `nil` when the balance is in a provider-defined unit.
    public let currency: String?
    public let expiresAt: Date?

    public init(
        remaining: Decimal,
        granted: Decimal? = nil,
        currency: String? = nil,
        expiresAt: Date? = nil
    ) throws(UsageError) {
        self.remaining = remaining
        self.granted = granted
        self.currency = currency
        self.expiresAt = expiresAt
        try validate()
    }

    /// Re-checks the invariants that the initialiser enforces, for values that arrive by decoding.
    public func validate() throws(UsageError) {
        try Self.requireNonNegative(remaining, field: "credits.remaining")
        if let granted {
            try Self.requireNonNegative(granted, field: "credits.granted")
        }
        if let currency {
            try CurrencyCode.validate(currency, field: "credits.currency")
        }
    }

    private static func requireNonNegative(_ value: Decimal, field: FieldName) throws(UsageError) {
        guard !value.isNaN else { throw UsageError.invalidValue(field: field, rule: .finite) }
        guard value >= 0 else { throw UsageError.invalidValue(field: field, rule: .nonNegative) }
    }
}
