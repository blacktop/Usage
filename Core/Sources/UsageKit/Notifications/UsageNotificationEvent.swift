import Foundation

/// A consumption boundary that can produce a user notification.
///
/// Thresholds are expressed as consumption because providers report consumption. User-facing
/// copy may invert the value to remaining capacity, but the crossing rule stays unambiguous here.
public enum UsageNotificationThreshold: String, Sendable, Hashable, CaseIterable {
    case warning
    case critical

    public var usedFraction: Double {
        switch self {
        case .warning: 0.80
        case .critical: 0.95
        }
    }
}

/// One account/window event the app may deliver through the platform notification center.
///
/// This carries only report data. Display names are app presentation metadata and credentials are
/// never part of a report, so neither can leak into persisted notification state through this type.
public struct UsageNotificationEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case threshold(UsageNotificationThreshold)
        case reset
    }

    public let accountKey: AccountKey
    public let windowID: WindowID
    public let windowLabel: String
    public let kind: Kind
    public let usedFraction: Double
    public let resetsAt: Date?

    public init(
        accountKey: AccountKey,
        windowID: WindowID,
        windowLabel: String,
        kind: Kind,
        usedFraction: Double,
        resetsAt: Date?
    ) {
        self.accountKey = accountKey
        self.windowID = windowID
        self.windowLabel = windowLabel
        self.kind = kind
        self.usedFraction = usedFraction
        self.resetsAt = resetsAt
    }
}
