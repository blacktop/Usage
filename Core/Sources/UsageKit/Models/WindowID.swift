/// Stable identity of a usage window, independent of the label a provider chooses to display.
///
/// Composed from provider-neutral concepts only: the scope the limit applies to, which of that
/// scope's windows it is, and the period it covers. The slot component is what stops a named
/// limit's primary and secondary windows from collapsing onto one identifier when both cover the
/// same period.
public struct WindowID: Sendable, Hashable, Codable, CustomStringConvertible {
    /// What the limit applies to.
    public enum Scope: Sendable, Hashable {
        /// The account plan's own aggregate limit.
        case plan
        /// A separately metered feature or resource named by the provider.
        case additional(feature: String)
    }

    /// Which of a scope's parallel windows this is.
    public enum Slot: String, Sendable, Hashable {
        case primary
        case secondary
    }

    /// The span the window covers.
    public enum Period: Sendable, Hashable {
        case session
        case daily
        case weekly
        case monthly
        case rolling(seconds: Int)
        case unspecified
    }

    public let rawValue: String
    public var description: String { rawValue }

    public init(scope: Scope, slot: Slot, period: Period) {
        rawValue = "\(Self.token(for: scope)):\(slot.rawValue):\(Self.token(for: period))"
    }

    /// Rehydrates an identifier previously produced by this type. Identifiers are opaque to
    /// readers, so any non-empty value round-trips.
    public init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let decoded = WindowID(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Window identifier must not be empty."
            )
        }
        self = decoded
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func token(for scope: Scope) -> String {
        switch scope {
        case .plan: "plan"
        case .additional(let feature): "additional:\(escape(feature))"
        }
    }

    private static func token(for period: Period) -> String {
        switch period {
        case .session: "session"
        case .daily: "daily"
        case .weekly: "weekly"
        case .monthly: "monthly"
        case .rolling(let seconds): "rolling-\(seconds)s"
        case .unspecified: "unspecified"
        }
    }

    /// Percent-escapes everything outside the unreserved set, so a feature name can never inject a
    /// component separator and can never lose information to normalisation.
    private static func escape(_ feature: String) -> String {
        var out = ""
        for byte in Array(feature.utf8) {
            if isUnreserved(byte) {
                out.append(Character(UnicodeScalar(byte)))
            } else {
                out.append("%")
                out.append(Hex.uppercasedPair(byte))
            }
        }
        return out
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        let isDigit = byte >= 0x30 && byte <= 0x39
        let isUpper = byte >= 0x41 && byte <= 0x5A
        let isLower = byte >= 0x61 && byte <= 0x7A
        let isMark = byte == 0x2D || byte == 0x2E || byte == 0x5F || byte == 0x7E
        return isDigit || isUpper || isLower || isMark
    }
}
