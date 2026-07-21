import Foundation

/// Maps a decoded Claude usage response onto the shared model.
enum ClaudeUsageMapper {
    /// Currency assumed when the payload states none. Anthropic bills these balances in USD.
    private static let defaultCurrency = "USD"
    /// Minor units per major unit. Amounts arrive in cents on both the OAuth and web APIs.
    private static let minorUnitsPerMajor = Decimal(100)

    static func report(
        from response: ClaudeUsageResponse,
        account: ProviderAccount,
        plan: String?,
        capturedAt: Date
    ) throws(UsageError) -> UsageReport {
        var collector = WindowCollector()
        appendPlanWindows(response, into: &collector)
        appendModelWindows(response, into: &collector)
        appendScopedWeeklyWindows(response.limits, into: &collector)
        let credits = creditBalance(response.extraUsage)
        guard !collector.windows.isEmpty || credits != nil else {
            throw UsageError.decodingFailure(field: "oauth.usage")
        }
        return try UsageReport(
            accountKey: account.key,
            plan: plan,
            windows: collector.windows,
            credits: credits,
            capturedAt: capturedAt,
            isPartial: response.hadDecodeFailure
        )
    }

    private static func appendPlanWindows(
        _ response: ClaudeUsageResponse,
        into collector: inout WindowCollector
    ) {
        collector.add(
            window(
                response.fiveHour,
                id: WindowID(scope: .plan, slot: .primary, period: .session),
                kind: .session,
                label: "Session",
                duration: .seconds(5 * 3_600)
            )
        )
        collector.add(
            window(
                response.sevenDay,
                id: WindowID(scope: .plan, slot: .secondary, period: .weekly),
                kind: .weekly,
                label: "Weekly",
                duration: .seconds(7 * 86_400)
            )
        )
    }

    private static func appendModelWindows(
        _ response: ClaudeUsageResponse,
        into collector: inout WindowCollector
    ) {
        let named: [(ClaudeWindowSnapshot?, String, String)] = [
            (response.sevenDayOpus, "opus", "Opus only"),
            (response.sevenDaySonnet, "sonnet", "Sonnet only"),
            (response.sevenDayOAuthApps, "oauth-apps", "Connected apps"),
            (response.sevenDayRoutines, "routines", "Routines"),
        ]
        for (snapshot, feature, label) in named {
            collector.add(
                window(
                    snapshot,
                    id: WindowID(
                        scope: .additional(feature: feature),
                        slot: .primary,
                        period: .weekly
                    ),
                    kind: .named(label),
                    label: label,
                    duration: .seconds(7 * 86_400)
                )
            )
        }
    }

    /// Emits the model-scoped weekly limits from the newer `limits` array.
    ///
    /// An "all models" scope is skipped: it restates the plan's own weekly window under a second
    /// identifier, which would double-count in the UI.
    private static func appendScopedWeeklyWindows(
        _ entries: [ClaudeLimitEntry],
        into collector: inout WindowCollector
    ) {
        for entry in entries where entry.group == "weekly" && entry.kind == "weekly_scoped" {
            guard let percent = entry.percent, percent.isFinite,
                let label = entry.modelDisplayName,
                let feature = FeatureSlug.make(entry.modelID ?? label),
                !isAllModels(feature)
            else { continue }
            collector.add(
                try? UsageWindow(
                    id: WindowID(
                        scope: .additional(feature: feature),
                        slot: .primary,
                        period: .weekly
                    ),
                    kind: .named(label),
                    label: "\(label) only",
                    usedFraction: percent / 100,
                    resetsAt: entry.resetsAt,
                    duration: .seconds(7 * 86_400)
                )
            )
        }
    }

    private static func isAllModels(_ feature: String) -> Bool {
        feature == "all-models" || feature.hasSuffix("-all-models")
    }

    private static func window(
        _ snapshot: ClaudeWindowSnapshot?,
        id: WindowID,
        kind: UsageWindow.Kind,
        label: String,
        duration: Duration
    ) -> UsageWindow? {
        guard let snapshot else { return nil }
        return try? UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedFraction: snapshot.utilization / 100,
            resetsAt: snapshot.resetsAt,
            duration: duration
        )
    }

    /// Converts the extra-usage allowance from minor units into a credit balance.
    ///
    /// A disabled or incomplete allowance produces no balance rather than a zero one, and an
    /// over-spend produces no balance rather than a negative remaining figure.
    private static func creditBalance(_ extra: ClaudeExtraUsage?) -> CreditBalance? {
        guard let extra, extra.isEnabled,
            let limit = extra.monthlyLimitMinorUnits,
            let used = extra.usedCreditsMinorUnits,
            limit >= used
        else { return nil }
        return try? CreditBalance(
            remaining: (limit - used) / minorUnitsPerMajor,
            granted: limit / minorUnitsPerMajor,
            currency: extra.currency ?? defaultCurrency
        )
    }
}
