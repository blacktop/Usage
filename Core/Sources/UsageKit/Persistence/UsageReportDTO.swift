import Foundation

/// Storage and wire shape of a `UsageReport`.
///
/// Deliberately hand-written rather than synthesized from the in-memory model: dates are epoch
/// seconds, durations are integer seconds, decimals are strings, and every field name is a
/// decision rather than a side effect of a property rename.
public struct UsageReportDTO: Sendable, Hashable, Codable {
    public let providerID: String
    public let accountID: String
    public let plan: String?
    public let capturedAt: Int64
    public let windows: [UsageWindowDTO]
    public let credits: CreditBalanceDTO?
    /// Present only when the report is partial, so a complete report's bytes are unchanged and an
    /// older reader sees exactly what it saw before.
    public let partial: Bool?

    public init(_ report: UsageReport) {
        providerID = report.accountKey.providerID.rawValue
        accountID = report.accountKey.accountID.rawValue
        plan = report.plan
        capturedAt = EpochSeconds.from(report.capturedAt)
        windows = report.windows.map(UsageWindowDTO.init)
        credits = report.credits.map(CreditBalanceDTO.init)
        partial = report.isPartial ? true : nil
    }

    /// Rebuilds the in-memory model, re-running every model invariant on the way.
    public func toModel() throws -> UsageReport {
        guard let accountID = AccountID(rawValue: accountID) else {
            throw UsageError.decodingFailure(field: "report.accountID")
        }
        return try UsageReport(
            accountKey: AccountKey(providerID: ProviderID(providerID), accountID: accountID),
            plan: plan,
            windows: windows.map { try $0.toModel() },
            credits: credits.map { try $0.toModel() },
            capturedAt: EpochSeconds.date(capturedAt),
            isPartial: partial ?? false
        )
    }
}

public struct UsageWindowDTO: Sendable, Hashable, Codable {
    public let id: String
    public let kind: WindowKindDTO
    public let label: String
    public let usedFraction: Double
    public let resetsAt: Int64?
    public let durationSeconds: Int64?
    public let detail: UsageDetailDTO?

    public init(_ window: UsageWindow) {
        id = window.id.rawValue
        kind = WindowKindDTO(window.kind)
        label = window.label
        usedFraction = window.usedFraction
        resetsAt = window.resetsAt.map(EpochSeconds.from)
        durationSeconds = window.duration.map { $0.components.seconds }
        detail = window.detail.map(UsageDetailDTO.init)
    }

    public func toModel() throws -> UsageWindow {
        guard let id = WindowID(rawValue: id) else {
            throw UsageError.decodingFailure(field: "window.id")
        }
        return try UsageWindow(
            id: id,
            kind: kind.toModel(),
            label: label,
            usedFraction: usedFraction,
            resetsAt: resetsAt.map(EpochSeconds.date),
            duration: durationSeconds.map { Duration.seconds($0) },
            detail: detail.map { try $0.toModel() }
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, label, usedFraction, resetsAt, durationSeconds, detail
    }

    /// Rejects non-finite fractions at the boundary, before they can reach a chart axis or a
    /// notification threshold comparison.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fraction = try container.decode(Double.self, forKey: .usedFraction)
        guard fraction.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .usedFraction,
                in: container,
                debugDescription: "usedFraction must be a finite number."
            )
        }
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(WindowKindDTO.self, forKey: .kind)
        label = try container.decode(String.self, forKey: .label)
        usedFraction = fraction
        resetsAt = try container.decodeIfPresent(Int64.self, forKey: .resetsAt)
        durationSeconds = try container.decodeIfPresent(Int64.self, forKey: .durationSeconds)
        detail = try container.decodeIfPresent(UsageDetailDTO.self, forKey: .detail)
    }
}

public struct WindowKindDTO: Sendable, Hashable, Codable {
    public let type: String
    public let name: String?

    public init(_ kind: UsageWindow.Kind) {
        switch kind {
        case .session: (type, name) = ("session", nil)
        case .weekly: (type, name) = ("weekly", nil)
        case .monthly: (type, name) = ("monthly", nil)
        case .named(let value): (type, name) = ("named", value)
        }
    }

    public func toModel() throws -> UsageWindow.Kind {
        switch (type, name) {
        case ("session", _): .session
        case ("weekly", _): .weekly
        case ("monthly", _): .monthly
        case ("named", .some(let value)): .named(value)
        default: throw UsageError.decodingFailure(field: "window.kind")
        }
    }
}

public enum UsageDetailDTO: Sendable, Hashable, Codable {
    case count(used: Int64, limit: Int64)
    case money(spent: String, budget: String, currency: String)

    public init(_ detail: UsageDetail) {
        switch detail {
        case .count(let used, let limit):
            self = .count(used: used, limit: limit)
        case .money(let spent, let budget, let currency):
            self = .money(
                spent: DecimalString.from(spent),
                budget: DecimalString.from(budget),
                currency: currency
            )
        }
    }

    public func toModel() throws -> UsageDetail {
        switch self {
        case .count(let used, let limit):
            return .count(used: used, limit: limit)
        case .money(let spent, let budget, let currency):
            return .money(
                spent: try DecimalString.decimal(spent, field: "detail.spent"),
                budget: try DecimalString.decimal(budget, field: "detail.budget"),
                currency: currency
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, used, limit, spent, budget, currency
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "count":
            self = .count(
                used: try container.decode(Int64.self, forKey: .used),
                limit: try container.decode(Int64.self, forKey: .limit)
            )
        case "money":
            self = .money(
                spent: try container.decode(String.self, forKey: .spent),
                budget: try container.decode(String.self, forKey: .budget),
                currency: try container.decode(String.self, forKey: .currency)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown usage detail kind '\(other)'."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .count(let used, let limit):
            try container.encode("count", forKey: .kind)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
        case .money(let spent, let budget, let currency):
            try container.encode("money", forKey: .kind)
            try container.encode(spent, forKey: .spent)
            try container.encode(budget, forKey: .budget)
            try container.encode(currency, forKey: .currency)
        }
    }
}

public struct CreditBalanceDTO: Sendable, Hashable, Codable {
    public let remaining: String
    public let granted: String?
    public let currency: String?
    public let expiresAt: Int64?

    public init(_ balance: CreditBalance) {
        remaining = DecimalString.from(balance.remaining)
        granted = balance.granted.map(DecimalString.from)
        currency = balance.currency
        expiresAt = balance.expiresAt.map(EpochSeconds.from)
    }

    public func toModel() throws -> CreditBalance {
        try CreditBalance(
            remaining: try DecimalString.decimal(remaining, field: "credits.remaining"),
            granted: try granted.map { try DecimalString.decimal($0, field: "credits.granted") },
            currency: currency,
            expiresAt: expiresAt.map(EpochSeconds.date)
        )
    }
}

enum EpochSeconds {
    static func from(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    static func date(_ seconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

enum DecimalString {
    static func from(_ value: Decimal) -> String {
        value.description
    }

    static func decimal(_ value: String, field: FieldName) throws(UsageError) -> Decimal {
        guard let decimal = Decimal(string: value), !decimal.isNaN else {
            throw UsageError.decodingFailure(field: field)
        }
        return decimal
    }
}
