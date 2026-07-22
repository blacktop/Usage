import Foundation

/// Pure notification policy over two consecutive reports for one account.
///
/// The evaluator performs no delivery and no persistence. Its caller is responsible for making the
/// current report durable before treating an event as delivered; that ordering is what prevents a
/// relaunch from replaying a threshold crossing.
public enum UsageNotificationEvaluator {
    /// Produces events only for windows present in both reports.
    ///
    /// A first observation establishes a baseline and never alerts. A partial response cannot make
    /// a missing window look reset, because absent windows are ignored rather than synthesized.
    public static func evaluate(
        previous: UsageReport?,
        current: UsageReport
    ) -> [UsageNotificationEvent] {
        guard let previous, previous.accountKey == current.accountKey else { return [] }
        let previousWindows = Dictionary(uniqueKeysWithValues: previous.windows.map { ($0.id, $0) })

        return current.windows.flatMap { window -> [UsageNotificationEvent] in
            guard let prior = previousWindows[window.id] else { return [] }
            return evaluate(
                previousUsedFraction: prior.usedFraction,
                previousResetsAt: prior.resetsAt,
                current: window,
                capturedAt: current.capturedAt,
                accountKey: current.accountKey
            )
        }
    }

    static func evaluate(
        previousUsedFraction: Double,
        previousResetsAt: Date?,
        current: UsageWindow,
        capturedAt: Date,
        accountKey: AccountKey
    ) -> [UsageNotificationEvent] {
        var events: [UsageNotificationEvent] = []
        if didCompleteReset(
            previousReset: previousResetsAt,
            nextReset: current.resetsAt,
            capturedAt: capturedAt
        ) {
            events.append(event(for: current, accountKey: accountKey, kind: .reset))
        }
        for threshold in UsageNotificationThreshold.allCases
        where previousUsedFraction < threshold.usedFraction
            && current.usedFraction >= threshold.usedFraction
        {
            events.append(
                event(for: current, accountKey: accountKey, kind: .threshold(threshold))
            )
        }
        return events
    }

    /// A changed future reset date proves a completed cycle only after the previously reported
    /// reset instant has actually passed. Merely moving a future estimate must not claim a reset.
    private static func didCompleteReset(
        previousReset: Date?,
        nextReset: Date?,
        capturedAt: Date
    ) -> Bool {
        guard let previousReset, let nextReset else {
            return false
        }
        return previousReset <= capturedAt && nextReset > previousReset
    }

    private static func event(
        for window: UsageWindow,
        accountKey: AccountKey,
        kind: UsageNotificationEvent.Kind
    ) -> UsageNotificationEvent {
        UsageNotificationEvent(
            accountKey: accountKey,
            windowID: window.id,
            windowLabel: window.label,
            kind: kind,
            usedFraction: window.usedFraction,
            resetsAt: window.resetsAt
        )
    }
}
