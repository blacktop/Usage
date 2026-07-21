import Foundation

/// One provider's answer for one account at one moment.
///
/// The shared shape carries no provider-specific field. Anything a provider treats as special is
/// expressed as a named `UsageWindow` or as `credits`.
public struct UsageReport: Sendable, Hashable, Codable {
    public let accountKey: AccountKey
    /// The provider's own plan label, verbatim: `"pro"`, `"team"`, `"copilot-business"`.
    public let plan: String?
    /// Ordered by the provider; the first window is the one it considers primary.
    public let windows: [UsageWindow]
    public let credits: CreditBalance?
    public let capturedAt: Date
    /// True when part of the provider's response could not be read, so at least one limit the
    /// account really has is missing here. Without it a dropped window is indistinguishable from a
    /// limit the account does not have, and the headline number silently describes the wrong thing.
    public let isPartial: Bool

    public init(
        accountKey: AccountKey,
        plan: String?,
        windows: [UsageWindow],
        credits: CreditBalance? = nil,
        capturedAt: Date,
        isPartial: Bool = false
    ) throws(UsageError) {
        var seen = Set<WindowID>()
        for window in windows where !seen.insert(window.id).inserted {
            throw UsageError.invalidValue(field: "windows.id", rule: .unique)
        }
        try credits?.validate()
        self.accountKey = accountKey
        self.plan = plan
        self.windows = windows
        self.credits = credits
        self.capturedAt = capturedAt
        self.isPartial = isPartial
    }

    private enum CodingKeys: String, CodingKey {
        case accountKey, plan, windows, credits, capturedAt, isPartial
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountKey: container.decode(AccountKey.self, forKey: .accountKey),
            plan: container.decodeIfPresent(String.self, forKey: .plan),
            windows: container.decode([UsageWindow].self, forKey: .windows),
            credits: container.decodeIfPresent(CreditBalance.self, forKey: .credits),
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            isPartial: container.decodeIfPresent(Bool.self, forKey: .isPartial) ?? false
        )
    }
}
