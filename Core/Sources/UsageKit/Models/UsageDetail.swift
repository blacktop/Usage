import Foundation

/// The absolute numbers behind a window's fraction, when the provider supplies them.
public enum UsageDetail: Sendable, Hashable, Codable {
    case count(used: Int64, limit: Int64)
    case money(spent: Decimal, budget: Decimal, currency: String)

    /// Rejects negative magnitudes, non-numeric decimals, malformed currency codes, and the one
    /// internally inconsistent shape: consumption against a zero allowance.
    public func validate(field: FieldName) throws(UsageError) {
        switch self {
        case .count(let used, let limit):
            try Self.requireNonNegative(used, field: FieldName("\(field).used"))
            try Self.requireNonNegative(limit, field: FieldName("\(field).limit"))
            guard limit > 0 || used == 0 else {
                throw UsageError.invalidValue(field: FieldName("\(field).used"), rule: .consistent)
            }
        case .money(let spent, let budget, let currency):
            try Self.requireNonNegative(spent, field: FieldName("\(field).spent"))
            try Self.requireNonNegative(budget, field: FieldName("\(field).budget"))
            try CurrencyCode.validate(currency, field: FieldName("\(field).currency"))
            guard budget > 0 || spent == 0 else {
                throw UsageError.invalidValue(field: FieldName("\(field).spent"), rule: .consistent)
            }
        }
    }

    private static func requireNonNegative(_ value: Int64, field: FieldName) throws(UsageError) {
        guard value >= 0 else { throw UsageError.invalidValue(field: field, rule: .nonNegative) }
    }

    private static func requireNonNegative(_ value: Decimal, field: FieldName) throws(UsageError) {
        guard !value.isNaN else { throw UsageError.invalidValue(field: field, rule: .finite) }
        guard value >= 0 else { throw UsageError.invalidValue(field: field, rule: .nonNegative) }
    }
}

/// Three-letter uppercase ASCII currency code, the only shape we accept from a provider.
enum CurrencyCode {
    static func validate(_ code: String, field: FieldName) throws(UsageError) {
        let scalars = Array(code.unicodeScalars)
        let isWellFormed = scalars.count == 3 && scalars.allSatisfy { ("A"..."Z").contains($0) }
        guard isWellFormed else {
            throw UsageError.invalidValue(field: field, rule: .currencyCode)
        }
    }
}
