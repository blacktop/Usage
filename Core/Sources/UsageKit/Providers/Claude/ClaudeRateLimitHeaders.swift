import Foundation

/// Subscription-window state returned on an inference request made with a setup token.
///
/// These unified headers are Claude Code OAuth headers, not the public API's per-minute rate-limit
/// contract. Values are consumed fractions in `0...1` (and may exceed one when over quota); reset
/// instants are Unix epoch seconds.
enum ClaudeRateLimitHeaders {
    private struct HeaderWindow {
        let fraction: Double
        let resetsAt: Date?
    }

    static func report(
        from response: HTTPResponse,
        account: ProviderAccount,
        capturedAt: Date
    ) throws(UsageError) -> UsageReport {
        var windows: [UsageWindow] = []
        var isPartial = false

        if let session = parse(
            "anthropic-ratelimit-unified-5h",
            in: response,
            isPartial: &isPartial
        ) {
            windows.append(
                try UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .session),
                    kind: .session,
                    label: "Session",
                    usedFraction: session.fraction,
                    resetsAt: session.resetsAt,
                    duration: .seconds(5 * 3_600)
                )
            )
        }
        if let weekly = parse(
            "anthropic-ratelimit-unified-7d",
            in: response,
            isPartial: &isPartial
        ) {
            windows.append(
                try UsageWindow(
                    id: WindowID(scope: .plan, slot: .secondary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: weekly.fraction,
                    resetsAt: weekly.resetsAt,
                    duration: .seconds(7 * 86_400)
                )
            )
        }

        guard !windows.isEmpty else {
            throw UsageError.decodingFailure(field: "ratelimit.headers")
        }
        return try UsageReport(
            accountKey: account.key,
            plan: "Claude setup token",
            windows: windows,
            capturedAt: capturedAt,
            // Unsupported model-scoped windows and credits are a source limitation, not a read
            // failure. Partial means one of the two headers this source promises was unreadable.
            isPartial: isPartial
        )
    }

    private static func parse(
        _ prefix: String,
        in response: HTTPResponse,
        isPartial: inout Bool
    ) -> HeaderWindow? {
        guard let rawFraction = response.headerValue("\(prefix)-utilization") else {
            isPartial = true
            return nil
        }
        guard let fraction = Double(rawFraction), fraction.isFinite, fraction >= 0 else {
            isPartial = true
            return nil
        }

        var resetsAt: Date?
        if let rawReset = response.headerValue("\(prefix)-reset") {
            if let seconds = TimeInterval(rawReset), seconds.isFinite, seconds >= 0 {
                resetsAt = Date(timeIntervalSince1970: seconds)
            } else {
                isPartial = true
            }
        } else {
            isPartial = true
        }
        return HeaderWindow(fraction: fraction, resetsAt: resetsAt)
    }
}
