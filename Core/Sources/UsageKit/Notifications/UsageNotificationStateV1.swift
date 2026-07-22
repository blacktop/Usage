import Foundation

/// Durable notification baselines, bounded to one observation per account and window.
public struct UsageNotificationStateV1: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public struct Record: Sendable, Hashable, Codable {
        public let providerID: String
        public let accountID: String
        public let windowID: String
        public let usedFraction: Double
        public let resetsAt: Int64?
        public let capturedAt: Int64

        public init(
            providerID: String,
            accountID: String,
            windowID: String,
            usedFraction: Double,
            resetsAt: Int64?,
            capturedAt: Int64
        ) {
            self.providerID = providerID
            self.accountID = accountID
            self.windowID = windowID
            self.usedFraction = usedFraction
            self.resetsAt = resetsAt
            self.capturedAt = capturedAt
        }

        private enum CodingKeys: String, CodingKey {
            case providerID, accountID, windowID, usedFraction, resetsAt, capturedAt
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let fraction = try container.decode(Double.self, forKey: .usedFraction)
            guard fraction.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .usedFraction,
                    in: container,
                    debugDescription: "usedFraction must be finite."
                )
            }
            providerID = try container.decode(String.self, forKey: .providerID)
            accountID = try container.decode(String.self, forKey: .accountID)
            windowID = try container.decode(String.self, forKey: .windowID)
            usedFraction = fraction
            resetsAt = try container.decodeIfPresent(Int64.self, forKey: .resetsAt)
            capturedAt = try container.decode(Int64.self, forKey: .capturedAt)
        }
    }

    public let schemaVersion: Int
    public let records: [Record]

    public init(records: [Record]) {
        schemaVersion = Self.currentSchemaVersion
        self.records = records.sorted {
            ($0.providerID, $0.accountID, $0.windowID)
                < ($1.providerID, $1.accountID, $1.windowID)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, records
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        try SchemaVersion.check(version, upTo: Self.currentSchemaVersion, in: container)
        self.init(records: try container.decode([Record].self, forKey: .records))
    }
}
