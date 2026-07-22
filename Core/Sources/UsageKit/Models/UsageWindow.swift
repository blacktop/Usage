import Foundation

/// One rate-limit or quota window belonging to an account.
///
/// Provider-specific concepts arrive here as a `Kind.named` window with a composed `WindowID`, so
/// no provider ever adds a field to this type.
public struct UsageWindow: Sendable, Hashable, Codable, Identifiable {
    /// The generic rendering category. Identity lives in `id`, not here.
    public enum Kind: Sendable, Hashable, Codable {
        case session
        case weekly
        case monthly
        case named(String)
    }

    public let id: WindowID
    public let kind: Kind
    public let label: String
    /// Fraction of the window consumed. Finite and at least zero; values above `1` are real
    /// over-quota states and are preserved here, clamped only at render time.
    public let usedFraction: Double
    public let resetsAt: Date?
    public let duration: Duration?
    public let detail: UsageDetail?

    public init(
        id: WindowID,
        kind: Kind,
        label: String,
        usedFraction: Double,
        resetsAt: Date? = nil,
        duration: Duration? = nil,
        detail: UsageDetail? = nil
    ) throws(UsageError) {
        guard usedFraction.isFinite else {
            throw UsageError.invalidValue(field: "usedFraction", rule: .finite)
        }
        guard usedFraction >= 0 else {
            throw UsageError.invalidValue(field: "usedFraction", rule: .nonNegative)
        }
        try detail?.validate(field: "detail")
        self.id = id
        self.kind = kind
        self.label = label
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
        self.duration = duration
        self.detail = detail
    }

    /// Capacity still available, clamped at zero once a window is exhausted or over quota.
    ///
    /// Providers, persistence, and history continue to speak in consumption. User-facing meters
    /// use this inverse so a freshly reset allowance reads as 100% left.
    public var remainingFraction: Double { max(0, 1 - usedFraction) }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, usedFraction, resetsAt, duration, detail
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(WindowID.self, forKey: .id),
            kind: container.decode(Kind.self, forKey: .kind),
            label: container.decode(String.self, forKey: .label),
            usedFraction: container.decode(Double.self, forKey: .usedFraction),
            resetsAt: container.decodeIfPresent(Date.self, forKey: .resetsAt),
            duration: container.decodeIfPresent(Duration.self, forKey: .duration),
            detail: container.decodeIfPresent(UsageDetail.self, forKey: .detail)
        )
    }
}
