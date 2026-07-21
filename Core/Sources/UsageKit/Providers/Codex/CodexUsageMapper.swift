import Foundation

/// Which of an account's two plan windows a snapshot is, decided by how long the window is.
///
/// The key position in the payload is not reliable: a `free` plan sends its weekly window in
/// `primary_window` with no secondary at all. Classification is tolerant rather than an equality
/// test against the two lengths seen so far, so a new plan with, say, a three-hour window does not
/// fall through to positional ordering.
enum CodexWindowPeriod: Sendable {
    case session
    case weekly

    static func classify(seconds: Int?) -> CodexWindowPeriod? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds <= 86_400 { return .session }
        if seconds >= 6 * 86_400 { return .weekly }
        return nil
    }
}

/// Maps a decoded usage response onto the shared model. Nothing Codex-specific leaves this file.
enum CodexUsageMapper {
    static func report(
        from response: CodexUsageResponse,
        account: ProviderAccount,
        fallbackPlan: String?,
        capturedAt: Date
    ) throws(UsageError) -> UsageReport {
        var collector = WindowCollector()
        appendPlanWindows(response.rateLimit, into: &collector)
        for entry in response.additionalRateLimits {
            appendAdditionalWindows(entry, into: &collector)
        }
        let credits = creditBalance(response.credits)
        // A response that yielded nothing is a shape change, not an account with no limits. An
        // empty report renders as a card with no rows, no error, and no way to tell the two apart.
        guard !collector.windows.isEmpty || credits != nil else {
            throw UsageError.decodingFailure(field: "wham.usage")
        }
        return try UsageReport(
            accountKey: account.key,
            plan: response.planType ?? fallbackPlan,
            windows: collector.windows,
            credits: credits,
            capturedAt: capturedAt,
            isPartial: response.hadDecodeFailure
        )
    }

    private static func appendPlanWindows(
        _ rateLimit: CodexRateLimit?,
        into collector: inout WindowCollector
    ) {
        guard let rateLimit else { return }
        let (session, weekly) = assignRoles(
            primary: rateLimit.primaryWindow,
            secondary: rateLimit.secondaryWindow
        )
        collector.add(
            window(
                session,
                id: WindowID(scope: .plan, slot: .primary, period: .session),
                kind: .session,
                label: "Session"
            )
        )
        collector.add(
            window(
                weekly,
                id: WindowID(scope: .plan, slot: .secondary, period: .weekly),
                kind: .weekly,
                label: "Weekly"
            )
        )
    }

    /// Swaps the two plan windows when the payload puts the weekly one first.
    ///
    /// Only an unambiguous swap is performed. When both windows classify the same way, or neither
    /// classifies at all, the payload's own ordering is kept rather than guessed at.
    private static func assignRoles(
        primary: CodexWindowSnapshot?,
        secondary: CodexWindowSnapshot?
    ) -> (session: CodexWindowSnapshot?, weekly: CodexWindowSnapshot?) {
        let primaryPeriod = primary.flatMap {
            CodexWindowPeriod.classify(seconds: $0.limitWindowSeconds)
        }
        let secondaryPeriod = secondary.flatMap {
            CodexWindowPeriod.classify(seconds: $0.limitWindowSeconds)
        }
        if primaryPeriod == .weekly, secondaryPeriod != .weekly {
            return (session: secondary, weekly: primary)
        }
        return (session: primary, weekly: secondary)
    }

    private static func appendAdditionalWindows(
        _ entry: CodexAdditionalRateLimit,
        into collector: inout WindowCollector
    ) {
        guard let feature = scopeFeature(of: entry), let rateLimit = entry.rateLimit else {
            return
        }
        let label = entry.limitName ?? entry.meteredFeature ?? feature
        let slots: [(CodexWindowSnapshot?, WindowID.Slot)] = [
            (rateLimit.primaryWindow, .primary),
            (rateLimit.secondaryWindow, .secondary),
        ]
        for (snapshot, slot) in slots {
            collector.add(
                window(
                    snapshot,
                    id: WindowID(
                        scope: .additional(feature: feature),
                        slot: slot,
                        period: period(of: snapshot)
                    ),
                    kind: .named(label),
                    label: label
                )
            )
        }
    }

    /// The scope component of an additional limit's window identifier.
    ///
    /// Composed from both names when they differ. One metered feature can carry several limits —
    /// requests and tokens over the same feature, say — and identity taken from the feature alone
    /// collapses them onto one identifier, so the second one is silently dropped and the user never
    /// sees the limit that is actually close to its ceiling.
    private static func scopeFeature(of entry: CodexAdditionalRateLimit) -> String? {
        let feature = FeatureSlug.make(entry.meteredFeature)
        let limit = FeatureSlug.make(entry.limitName)
        guard let feature else { return limit }
        guard let limit, limit != feature else { return feature }
        return "\(feature)-\(limit)"
    }

    private static func period(of snapshot: CodexWindowSnapshot?) -> WindowID.Period {
        guard let seconds = snapshot?.limitWindowSeconds, seconds > 0 else { return .unspecified }
        switch CodexWindowPeriod.classify(seconds: seconds) {
        case .session: return .session
        case .weekly: return .weekly
        case nil: return .rolling(seconds: seconds)
        }
    }

    private static func window(
        _ snapshot: CodexWindowSnapshot?,
        id: WindowID,
        kind: UsageWindow.Kind,
        label: String
    ) -> UsageWindow? {
        guard let snapshot else { return nil }
        return try? UsageWindow(
            id: id,
            kind: kind,
            label: label,
            usedFraction: Double(snapshot.usedPercent) / 100,
            resetsAt: ProviderDates.epochSeconds(snapshot.resetAt),
            duration: ProviderDates.windowDuration(seconds: snapshot.limitWindowSeconds)
        )
    }

    /// An unlimited or absent balance is reported as no balance rather than as zero.
    private static func creditBalance(_ credits: CodexCredits?) -> CreditBalance? {
        guard let credits, credits.hasCredits, !credits.unlimited, let balance = credits.balance
        else { return nil }
        return try? CreditBalance(remaining: balance)
    }
}
