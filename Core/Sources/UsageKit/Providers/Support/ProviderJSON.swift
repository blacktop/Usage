import Foundation

/// A coding key for documents whose keys are data — a Copilot `apps.json` map, a Codex payload that
/// spells the same field two ways — rather than a fixed schema.
struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        nil
    }
}

extension KeyedDecodingContainer where Key == AnyCodingKey {
    /// The first of `names` that holds a non-empty string.
    ///
    /// Agent credential files spell the same field snake_case in one release and camelCase in the
    /// next, so every read accepts both rather than losing the value on a rename.
    func trimmedString(_ names: String...) -> String? {
        for name in names {
            let raw = try? decodeIfPresent(String.self, forKey: AnyCodingKey(name))
            if let trimmed = raw?.trimmedNonEmpty { return trimmed }
        }
        return nil
    }

    func lenientInt(_ names: String...) -> Int? {
        for name in names {
            if let value = try? decodeIfPresent(LenientInt.self, forKey: AnyCodingKey(name)) {
                return value.value
            }
        }
        return nil
    }

    func lenientDecimal(_ names: String...) -> Decimal? {
        for name in names {
            if let value = try? decodeIfPresent(LenientDecimal.self, forKey: AnyCodingKey(name)) {
                return value.value
            }
        }
        return nil
    }

    func lenientBool(_ names: String..., default fallback: Bool) -> Bool {
        for name in names {
            if let value = try? decodeIfPresent(Bool.self, forKey: AnyCodingKey(name)) {
                return value
            }
        }
        return fallback
    }

    func nested(_ name: String) -> KeyedDecodingContainer<AnyCodingKey>? {
        try? nestedContainer(keyedBy: AnyCodingKey.self, forKey: AnyCodingKey(name))
    }
}

extension String {
    /// `self` without surrounding whitespace, or `nil` when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Literal endpoint and dashboard URLs.
///
/// `URL(string:)` is failable and force-unwrapping is banned, so the fallback keeps the type
/// non-optional. Every literal that goes through here is asserted in a provider request test, which
/// is what actually proves the fallback is unreachable.
enum StaticURL {
    static func make(_ string: String) -> URL {
        URL(string: string) ?? URL(filePath: "/")
    }
}
