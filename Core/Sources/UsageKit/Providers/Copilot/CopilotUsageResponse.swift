import Foundation

/// Body of `GET https://api.github.com/copilot_internal/user`.
///
/// GitHub varies this shape by plan — free, individual, business, enterprise, token-based billing —
/// so every member is optional and the quota map is decoded entry by entry.
struct CopilotUsageResponse: Decodable, Sendable {
    let copilotPlan: String?
    /// Business and enterprise seats billed per token report placeholder quotas that must not
    /// render as "0% used".
    let tokenBasedBilling: Bool
    let quotaResetAt: Date?
    let quotaSnapshots: [String: CopilotQuotaSnapshot]
    let monthlyQuotas: CopilotQuotaCounts?
    let limitedUserQuotas: CopilotQuotaCounts?
    let hadDecodeFailure: Bool

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        copilotPlan = root.trimmedString("copilot_plan")
        tokenBasedBilling = root.lenientBool("token_based_billing", default: false)
        quotaResetAt = ProviderDates.calendarDayOrISO8601(root.trimmedString("quota_reset_date"))
        let snapshots = root.lossyDictionary(
            CopilotQuotaSnapshot.self,
            forKey: AnyCodingKey("quota_snapshots")
        )
        let monthly = root.lossy(CopilotQuotaCounts.self, forKey: AnyCodingKey("monthly_quotas"))
        let limited = root.lossy(
            CopilotQuotaCounts.self,
            forKey: AnyCodingKey("limited_user_quotas")
        )
        quotaSnapshots = snapshots.value ?? [:]
        monthlyQuotas = monthly.value
        limitedUserQuotas = limited.value
        hadDecodeFailure = snapshots.failed || monthly.failed || limited.failed
    }

    static func decode(_ data: Data) throws(UsageError) -> CopilotUsageResponse {
        guard let response = try? JSONDecoder().decode(CopilotUsageResponse.self, from: data) else {
            throw UsageError.decodingFailure(field: "copilot_internal.user")
        }
        return response
    }
}

/// One entry of `quota_snapshots`. Numbers arrive as JSON numbers or as quoted strings.
struct CopilotQuotaSnapshot: Decodable, Sendable {
    let entitlement: Decimal?
    let remaining: Decimal?
    let percentRemaining: Double?
    let unlimited: Bool

    init(entitlement: Decimal?, remaining: Decimal?, percentRemaining: Double?, unlimited: Bool) {
        self.entitlement = entitlement
        self.remaining = remaining
        self.percentRemaining = percentRemaining
        self.unlimited = unlimited
    }

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        entitlement = root.lenientDecimal("entitlement")
        remaining = root.lenientDecimal("remaining")
        percentRemaining = root.lenientDecimal("percent_remaining")
            .map { Double(truncating: $0 as NSDecimalNumber) }
        unlimited = root.lenientBool("unlimited", default: false)
    }

    /// A seat with no metered allowance at all.
    ///
    /// GitHub reports `{entitlement: 0, remaining: 0, percent_remaining: 100}` for token-based
    /// billing, which would otherwise render as a healthy, empty quota. The absent members carry
    /// the same meaning: an entitlement that is missing or non-positive states no allowance, and
    /// requiring `remaining` to agree would let `{entitlement: 0, percent_remaining: 100}` — the
    /// same placeholder with one field dropped — through as "0% used".
    var isPlaceholder: Bool {
        guard let entitlement else { return true }
        return entitlement <= 0
    }

    /// Percent consumed, derived from the remaining count when the percentage is absent.
    /// May exceed 100 on an over-quota seat.
    ///
    /// A percentage is only meaningful once a positive allowance is stated, so a bare
    /// `percent_remaining` is not enough on its own.
    var usedPercent: Double? {
        guard let entitlement, entitlement > 0 else { return nil }
        if let percentRemaining { return 100 - percentRemaining }
        guard let remaining else { return nil }
        let consumed = (entitlement - remaining) / entitlement * 100
        return Double(truncating: consumed as NSDecimalNumber)
    }
}

/// `monthly_quotas` (the entitlement) and `limited_user_quotas` (what is left of it).
struct CopilotQuotaCounts: Decodable, Sendable {
    let chat: Decimal?
    let completions: Decimal?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        chat = root.lenientDecimal("chat")
        completions = root.lenientDecimal("completions")
    }

    func value(for feature: String) -> Decimal? {
        switch feature {
        case "chat": chat
        case "completions": completions
        default: nil
        }
    }
}
