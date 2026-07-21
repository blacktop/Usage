import Foundation

/// Maps a decoded Copilot quota response onto the shared model.
///
/// Every quota becomes its own named window keyed by the feature GitHub reports, rather than being
/// forced into fixed "premium" and "chat" slots. That removes the reference's substring-matching
/// heuristic, which mislabels any quota key it has not seen before.
enum CopilotUsageMapper {
    /// Features whose counts `monthly_quotas` and `limited_user_quotas` carry.
    private static let derivableFeatures = ["chat", "completions"]

    static func report(
        from response: CopilotUsageResponse,
        account: ProviderAccount,
        capturedAt: Date
    ) throws(UsageError) -> UsageReport {
        var measured: [String: CopilotQuotaSnapshot] = [:]
        var unmeteredFeatures = false
        for key in response.quotaSnapshots.keys.sorted() {
            guard let snapshot = response.quotaSnapshots[key] else { continue }
            guard !snapshot.unlimited, !snapshot.isPlaceholder else {
                unmeteredFeatures = true
                continue
            }
            measured[key] = snapshot
        }
        for feature in derivableFeatures where measured[feature] == nil {
            measured[feature] = derivedSnapshot(for: feature, from: response)
        }

        var collector = WindowCollector()
        for key in measured.keys.sorted() {
            collector.add(window(measured[key], feature: key, resetsAt: response.quotaResetAt))
        }
        guard !collector.windows.isEmpty || unmeteredFeatures || response.tokenBasedBilling else {
            throw UsageError.decodingFailure(field: "quota_snapshots")
        }
        return try UsageReport(
            accountKey: account.key,
            plan: response.copilotPlan?.capitalized,
            windows: collector.windows,
            capturedAt: capturedAt,
            isPartial: response.hadDecodeFailure
        )
    }

    /// Builds a snapshot from the monthly entitlement and what is left of it.
    ///
    /// Used only when the feature has no usable direct snapshot, so an unlimited direct entry loses
    /// to a real monthly count rather than hiding it.
    private static func derivedSnapshot(
        for feature: String,
        from response: CopilotUsageResponse
    ) -> CopilotQuotaSnapshot? {
        guard let entitlement = response.monthlyQuotas?.value(for: feature), entitlement > 0,
            let remaining = response.limitedUserQuotas?.value(for: feature), remaining >= 0
        else { return nil }
        return CopilotQuotaSnapshot(
            entitlement: entitlement,
            remaining: remaining,
            percentRemaining: nil,
            unlimited: false
        )
    }

    private static func window(
        _ snapshot: CopilotQuotaSnapshot?,
        feature: String,
        resetsAt: Date?
    ) -> UsageWindow? {
        guard let snapshot, let usedPercent = snapshot.usedPercent, usedPercent.isFinite,
            let slug = FeatureSlug.make(feature)
        else { return nil }
        let label = humanized(feature)
        return try? UsageWindow(
            id: WindowID(scope: .additional(feature: slug), slot: .primary, period: .monthly),
            kind: .named(label),
            label: label,
            usedFraction: max(0, usedPercent) / 100,
            resetsAt: resetsAt,
            detail: detail(of: snapshot)
        )
    }

    /// Absolute counts, when the payload states both sides and they are consistent.
    private static func detail(of snapshot: CopilotQuotaSnapshot) -> UsageDetail? {
        guard let entitlement = snapshot.entitlement, entitlement > 0,
            let remaining = snapshot.remaining, remaining >= 0, remaining <= entitlement,
            let limit = wholeNumber(entitlement), let left = wholeNumber(remaining)
        else { return nil }
        return .count(used: limit - left, limit: limit)
    }

    private static func wholeNumber(_ value: Decimal) -> Int64? {
        let rounded = NSDecimalNumber(decimal: value).rounding(accordingToBehavior: nil)
        guard rounded.doubleValue >= 0, rounded.doubleValue <= Double(Int64.max) else { return nil }
        return rounded.int64Value
    }

    /// `premium_interactions` reads as "Premium interactions" without a lookup table that would go
    /// stale the moment GitHub adds a quota.
    private static func humanized(_ feature: String) -> String {
        let spaced = feature.replacingOccurrences(of: "_", with: " ")
        guard let first = spaced.first else { return feature }
        return first.uppercased() + spaced.dropFirst()
    }
}
