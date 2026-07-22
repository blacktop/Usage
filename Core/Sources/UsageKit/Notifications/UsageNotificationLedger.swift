import Foundation

/// In-memory notification baselines with a versioned, token-free durable representation.
public struct UsageNotificationLedger: Sendable, Hashable {
    private struct Key: Sendable, Hashable {
        let account: AccountKey
        let window: WindowID
    }

    private struct Observation: Sendable, Hashable {
        let usedFraction: Double
        let resetsAt: Date?
        let capturedAt: Date
    }

    private var observations: [Key: Observation]

    public init() {
        observations = [:]
    }

    /// Loads state through the current alias map. If two retired identities now resolve to one
    /// account, the newest baseline wins rather than allowing the older identity to re-notify.
    public init(
        state: UsageNotificationStateV1,
        reconciler: IdentityReconciler
    ) throws {
        observations = [:]
        for record in state.records {
            guard let accountID = AccountID(rawValue: record.accountID),
                let windowID = WindowID(rawValue: record.windowID)
            else {
                throw UsageError.decodingFailure(field: "notificationState.identity")
            }
            let unresolved = AccountKey(
                providerID: ProviderID(record.providerID),
                accountID: accountID
            )
            let key = Key(account: reconciler.resolve(unresolved), window: windowID)
            let candidate = Observation(
                usedFraction: record.usedFraction,
                resetsAt: record.resetsAt.map(EpochSeconds.date),
                capturedAt: EpochSeconds.date(record.capturedAt)
            )
            if let existing = observations[key], existing.capturedAt > candidate.capturedAt {
                continue
            }
            observations[key] = candidate
        }
    }

    /// Evaluates and records one report. Older out-of-order reports cannot rewind dedupe state.
    public mutating func evaluate(
        _ report: UsageReport,
        resolvingWith reconciler: IdentityReconciler
    ) -> [UsageNotificationEvent] {
        let account = reconciler.resolve(report.accountKey)
        var events: [UsageNotificationEvent] = []
        for window in report.windows {
            let key = Key(account: account, window: window.id)
            if let previous = observations[key] {
                guard report.capturedAt >= previous.capturedAt else { continue }
                events.append(
                    contentsOf: UsageNotificationEvaluator.evaluate(
                        previousUsedFraction: previous.usedFraction,
                        previousResetsAt: previous.resetsAt,
                        current: window,
                        capturedAt: report.capturedAt,
                        accountKey: account
                    )
                )
            }
            observations[key] = Observation(
                usedFraction: window.usedFraction,
                resetsAt: window.resetsAt,
                capturedAt: report.capturedAt
            )
        }
        return events
    }

    public var state: UsageNotificationStateV1 {
        UsageNotificationStateV1(
            records: observations.map { key, observation in
                UsageNotificationStateV1.Record(
                    providerID: key.account.providerID.rawValue,
                    accountID: key.account.accountID.rawValue,
                    windowID: key.window.rawValue,
                    usedFraction: observation.usedFraction,
                    resetsAt: observation.resetsAt.map(EpochSeconds.from),
                    capturedAt: EpochSeconds.from(observation.capturedAt)
                )
            }
        )
    }
}
