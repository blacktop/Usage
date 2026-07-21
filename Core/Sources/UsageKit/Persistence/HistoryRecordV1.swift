import Foundation

/// One append-only history line.
///
/// The envelope is explicit so a model rename can never silently change the on-disk schema:
/// `schemaVersion` gates readers, `recordedAt` is when the app decided to sample, and
/// `report.capturedAt` is when the provider answered.
public struct HistoryRecordV1: Sendable, Hashable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let recordedAt: Int64
    public let report: UsageReportDTO

    public init(report: UsageReport, recordedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.recordedAt = EpochSeconds.from(recordedAt)
        self.report = UsageReportDTO(report)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, recordedAt, report
    }

    /// Unknown keys are ignored, so a future writer can add fields without breaking this reader.
    /// An unknown *version* is rejected, because that is a shape change we cannot interpret.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        try SchemaVersion.check(version, upTo: Self.currentSchemaVersion, in: container)
        schemaVersion = version
        recordedAt = try container.decode(Int64.self, forKey: .recordedAt)
        report = try container.decode(UsageReportDTO.self, forKey: .report)
    }
}
