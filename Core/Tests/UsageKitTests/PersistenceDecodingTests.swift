import Foundation
import Testing

@testable import UsageKit

@Suite("Persistence decoding")
struct PersistenceDecodingTests {
    private static let accountID = Fixtures.canonicalKey("x").accountID.rawValue

    private func reportJSON(
        accountID: String = PersistenceDecodingTests.accountID,
        window: String = #"{"id":"plan:primary:weekly","kind":{"type":"weekly"},"#
            + #""label":"Weekly","usedFraction":0.5}"#,
        credits: String = "null"
    ) -> String {
        """
        {"providerID":"preview","accountID":"\(accountID)","plan":"pro",
         "capturedAt":1700000000,"windows":[\(window)],"credits":\(credits)}
        """
    }

    private func decodeReport(_ json: String) throws -> UsageReportDTO {
        try UsageJSON.decoder().decode(UsageReportDTO.self, from: Data(json.utf8))
    }

    /// A decoder that accepts the textual spellings of non-finite doubles, so the DTO's own
    /// rejection is what the test observes rather than `JSONDecoder`'s default.
    private func permissiveDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        return decoder
    }

    @Test("Unknown future fields are ignored at every level of the envelope")
    func unknownFieldsAreTolerated() throws {
        let data = Data(
            """
            {"schemaVersion":1,"recordedAt":1700000060,"sampledBy":"future-app",
             "report":{"providerID":"preview","accountID":"\(Self.accountID)",
             "plan":"pro","capturedAt":1700000000,"region":"eu",
             "windows":[{"id":"plan:primary:weekly","kind":{"type":"weekly","emoji":"x"},
             "label":"Weekly","usedFraction":0.5,"trend":"up",
             "detail":{"kind":"count","used":5,"limit":10,"pending":2}}],
             "credits":{"remaining":"3","tier":"gold"}}}
            """.utf8
        )
        let record = try UsageJSON.decoder().decode(HistoryRecordV1.self, from: data)
        let report = try record.report.toModel()
        #expect(report.windows.count == 1)
        #expect(report.windows[0].detail == .count(used: 5, limit: 10))
        #expect(report.credits?.remaining == Decimal(3))
    }

    @Test(
        "Non-finite fractions are rejected on decode", arguments: ["NaN", "Infinity", "-Infinity"])
    func nonFiniteFractionsAreRejected(literal: String) throws {
        let json = reportJSON(
            window: #"{"id":"plan:primary:weekly","kind":{"type":"weekly"},"#
                + #""label":"Weekly","usedFraction":"\#(literal)"}"#
        )
        #expect(throws: DecodingError.self) {
            try permissiveDecoder().decode(UsageReportDTO.self, from: Data(json.utf8))
        }
    }

    @Test("A negative fraction survives decoding but is rejected when rebuilt as a model")
    func negativeFractionIsRejectedByTheModel() throws {
        let dto = try decodeReport(
            reportJSON(
                window: #"{"id":"plan:primary:weekly","kind":{"type":"weekly"},"#
                    + #""label":"Weekly","usedFraction":-0.5}"#
            )
        )
        #expect(throws: UsageError.invalidValue(field: "usedFraction", rule: .nonNegative)) {
            try dto.toModel()
        }
    }

    @Test("An unreadable schema version is rejected rather than guessed at", arguments: [0, 2, 99])
    func unsupportedSchemaVersionsAreRejected(version: Int) throws {
        let history = Data(#"{"schemaVersion":\#(version),"recordedAt":1,"report":{}}"#.utf8)
        let output = Data(
            #"{"schemaVersion":\#(version),"generatedAt":1,"accounts":[],"failures":[]}"#.utf8
        )
        let aliases = Data(#"{"schemaVersion":\#(version),"aliases":[]}"#.utf8)
        #expect(throws: DecodingError.self) {
            try UsageJSON.decoder().decode(HistoryRecordV1.self, from: history)
        }
        #expect(throws: DecodingError.self) {
            try UsageJSON.decoder().decode(UsageOutputV1.self, from: output)
        }
        #expect(throws: DecodingError.self) {
            try UsageJSON.decoder().decode(IdentityAliasMapV1.self, from: aliases)
        }
    }

    @Test("An unknown detail kind is rejected instead of silently dropping the numbers")
    func unknownDetailKindIsRejected() {
        let data = Data(#"{"kind":"tokens","used":1,"limit":2}"#.utf8)
        #expect(throws: DecodingError.self) {
            try UsageJSON.decoder().decode(UsageDetailDTO.self, from: data)
        }
    }

    @Test("A named window kind without a name is rejected when rebuilt")
    func namedKindRequiresAName() throws {
        let dto = try decodeReport(
            reportJSON(
                window: #"{"id":"plan:primary:weekly","kind":{"type":"named"},"#
                    + #""label":"Weekly","usedFraction":0.5}"#
            )
        )
        #expect(throws: UsageError.decodingFailure(field: "window.kind")) { try dto.toModel() }
    }

    @Test("A malformed account identifier is rejected when rebuilt")
    func malformedAccountIdentifierIsRejected() throws {
        let dto = try decodeReport(reportJSON(accountID: "not-a-digest"))
        #expect(throws: UsageError.decodingFailure(field: "report.accountID")) { try dto.toModel() }
    }

    @Test("A non-numeric decimal string is rejected when rebuilt")
    func malformedDecimalIsRejected() throws {
        let dto = try decodeReport(reportJSON(credits: #"{"remaining":"twelve"}"#))
        #expect(throws: UsageError.decodingFailure(field: "credits.remaining")) {
            try dto.toModel()
        }
    }

    @Test("Epoch seconds and integer durations survive a full round trip")
    func timeFieldsRoundTrip() throws {
        let report = try Fixtures.goldenReport()
        let rebuilt = try UsageReportDTO(report).toModel()
        #expect(rebuilt.capturedAt == report.capturedAt)
        #expect(rebuilt.windows[0].resetsAt == report.windows[0].resetsAt)
        #expect(rebuilt.windows[0].duration == .seconds(18_000))
        #expect(rebuilt.windows[1].resetsAt == nil)
        #expect(rebuilt.credits?.expiresAt == report.credits?.expiresAt)
        #expect(rebuilt == report)
    }
}
