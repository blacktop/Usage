import Foundation

/// A value that may have been dropped, plus whether dropping it was a decode failure.
///
/// The distinction matters: an absent key is normal for an undocumented endpoint, while a present
/// key we could not read means the report is partial and should be reported as such.
struct LossyValue<Wrapped>: Sendable where Wrapped: Sendable {
    let value: Wrapped?
    let failed: Bool

    static var absent: LossyValue<Wrapped> { LossyValue(value: nil, failed: false) }
}

/// Per-element lossy decoding wrapper.
///
/// Decoding `[LossyElement<T>]` always succeeds and yields `nil` for exactly the elements that
/// failed, so one malformed sibling cannot discard the rest of the array. `decodeIfPresent` on a
/// plain `[T]` cannot do that: the first bad element throws and the entire array becomes `nil`.
struct LossyElement<Wrapped: Decodable & Sendable>: Decodable, Sendable {
    let value: Wrapped?

    init(from decoder: any Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

extension KeyedDecodingContainer {
    /// Decodes `key`, treating an unreadable value as absent rather than failing its siblings.
    func lossy<T: Decodable & Sendable>(_ type: T.Type, forKey key: Key) -> LossyValue<T> {
        guard hasValue(forKey: key) else { return .absent }
        guard let value = try? decode(T.self, forKey: key) else {
            return LossyValue(value: nil, failed: true)
        }
        return LossyValue(value: value, failed: false)
    }

    /// Decodes an array element-wise, keeping every element that reads cleanly.
    func lossyArray<T: Decodable & Sendable>(_ type: T.Type, forKey key: Key) -> LossyValue<[T]> {
        guard hasValue(forKey: key) else { return .absent }
        guard let elements = try? decode([LossyElement<T>].self, forKey: key) else {
            return LossyValue(value: nil, failed: true)
        }
        let kept = elements.compactMap(\.value)
        return LossyValue(value: kept, failed: kept.count != elements.count)
    }

    /// Decodes a JSON object as a dictionary, entry by entry, keeping every entry that reads
    /// cleanly. Providers that key quotas by feature name arrive in this shape.
    func lossyDictionary<T: Decodable & Sendable>(
        _ type: T.Type,
        forKey key: Key
    ) -> LossyValue<[String: T]> {
        guard hasValue(forKey: key) else { return .absent }
        guard let entries = try? decode([String: LossyElement<T>].self, forKey: key) else {
            return LossyValue(value: nil, failed: true)
        }
        let kept = entries.compactMapValues(\.value)
        return LossyValue(value: kept, failed: kept.count != entries.count)
    }

    private func hasValue(forKey key: Key) -> Bool {
        contains(key) && (try? decodeNil(forKey: key)) == false
    }
}

/// A number that arrives as a JSON number on some accounts and as a quoted string on others.
///
/// Real Codex and Copilot responses do both for the same field, so a strict `Double` would drop a
/// valid value. Parsing money through `Decimal` rather than `Double` keeps balances exact.
struct LenientDecimal: Decodable, Sendable {
    let value: Decimal

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let decimal = try? container.decode(Decimal.self) {
            value = decimal
            return
        }
        if let string = try? container.decode(String.self),
            let decimal = Decimal(
                string: string.trimmingCharacters(in: .whitespaces),
                locale: Locale(identifier: "en_US_POSIX")
            )
        {
            value = decimal
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected a number or a numeric string."
        )
    }

    var double: Double { Double(truncating: value as NSDecimalNumber) }
}

/// An integer that may arrive as a JSON integer, a whole JSON float, or a quoted string.
struct LenientInt: Decodable, Sendable {
    private static let representableBound = 9e15

    let value: Int

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            value = integer
            return
        }
        if let double = try? container.decode(Double.self), double.isFinite,
            abs(double) <= Self.representableBound
        {
            value = Int(double.rounded())
            return
        }
        if let string = try? container.decode(String.self),
            let integer = Int(string.trimmingCharacters(in: .whitespaces))
        {
            value = integer
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Expected an integer or an integral string."
        )
    }
}
