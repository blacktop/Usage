import Foundation
import Testing

@testable import UsageKit

/// These lock the persisted and published byte shapes. If one fails, the schema changed: bump the
/// version and migrate, or put the field back. Do not "fix" the expectation.
@Suite("Golden schemas")
struct SchemaGoldenTests {
    private static let goldenAccountID =
        "c1:5c5cd4db02610b86946d409f13ead74f429db0aa2a8fc590a35ee9a6479f9d07"
    private static let retiredAccountID =
        "s1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    @Test("HistoryRecordV1 encodes to its documented shape")
    func historyRecordGolden() throws {
        let record = HistoryRecordV1(
            report: try Fixtures.goldenReport(),
            recordedAt: Fixtures.recordedAt
        )
        #expect(try Fixtures.encodedString(record) == Self.expectedHistoryJSON)
    }

    @Test("HistoryRecordV1 round-trips back to an equal model")
    func historyRecordRoundTrips() throws {
        let report = try Fixtures.goldenReport()
        let record = HistoryRecordV1(report: report, recordedAt: Fixtures.recordedAt)
        let data = try UsageJSON.encoder().encode(record)
        let decoded = try UsageJSON.decoder().decode(HistoryRecordV1.self, from: data)
        #expect(decoded == record)
        #expect(try decoded.report.toModel() == report)
    }

    @Test("UsageOutputV1 encodes to its documented shape")
    func usageOutputGolden() throws {
        let output = UsageOutputV1(
            generatedAt: Fixtures.recordedAt,
            accounts: [
                UsageOutputV1.Account(
                    label: "golden@example.com",
                    report: UsageReportDTO(try Fixtures.goldenReport())
                )
            ],
            failures: [
                UsageOutputV1.Failure(
                    providerID: ProviderID("claude"),
                    accountID: nil,
                    error: UsageError(
                        category: .rateLimited,
                        reason: .httpStatus(code: 429),
                        retry: UsageError.RetryAdvice(delay: .seconds(30), scope: .provider)
                    )
                )
            ]
        )
        #expect(try Fixtures.encodedString(output) == Self.expectedOutputJSON)
    }

    @Test("A failure carrying a reauthentication action encodes to its documented shape")
    func reauthenticationFailureGolden() throws {
        let failure = UsageOutputV1.Failure(
            providerID: ProviderID("codex"),
            accountID: nil,
            error: UsageError(
                category: .authenticationExpired,
                reason: .httpStatus(code: 401)
            )
            .offering(ReauthAction(summary: "Sign in again.", command: "codex login"))
        )
        #expect(
            try Fixtures.encodedString(failure) == """
                {"category":"authenticationExpired",\
                "message":"The provider returned HTTP 401.","providerID":"codex",\
                "reauth":{"command":"codex login","summary":"Sign in again."}}
                """
        )
    }

    @Test("A failure without an action omits the field rather than emitting a null")
    func failureWithoutAnActionIsUnchanged() throws {
        let failure = UsageOutputV1.Failure(
            providerID: ProviderID("codex"),
            accountID: nil,
            error: UsageError(category: .network, reason: .transportFailure)
        )
        #expect(!(try Fixtures.encodedString(failure)).contains("reauth"))
    }

    @Test("UsageOutputV1 round-trips back to an equal envelope")
    func usageOutputRoundTrips() throws {
        let output = UsageOutputV1(
            generatedAt: Fixtures.recordedAt,
            accounts: [
                UsageOutputV1.Account(
                    label: nil,
                    report: UsageReportDTO(try Fixtures.goldenReport())
                )
            ],
            failures: []
        )
        let data = try UsageJSON.encoder().encode(output)
        #expect(try UsageJSON.decoder().decode(UsageOutputV1.self, from: data) == output)
    }

    @Test("The golden account identity is the documented SHA-256 derivation")
    func goldenAccountIdentityIsStable() {
        let id = AccountID.canonical(provider: Fixtures.provider, canonicalID: "golden")
        #expect(id.rawValue == Self.goldenAccountID)
    }

    @Test("IdentityAliasMapV1 encodes to its documented shape")
    func aliasMapGolden() throws {
        let map = IdentityAliasMapV1(aliases: [
            IdentityAliasMapV1.Alias(
                providerID: "preview",
                retiredAccountID: Self.retiredAccountID,
                canonicalAccountID: Self.goldenAccountID,
                recordedAt: 1_700_000_060
            )
        ])
        #expect(try Fixtures.encodedString(map) == Self.expectedAliasMapJSON)
    }

    private static let expectedReportJSON = """
        {"accountID":"\(goldenAccountID)",\
        "capturedAt":1700000000,\
        "credits":{"currency":"USD","expiresAt":1702592000,"granted":"50","remaining":"35"},\
        "plan":"pro","providerID":"preview","windows":[\
        {"detail":{"kind":"count","limit":100,"used":25},"durationSeconds":18000,\
        "id":"plan:primary:session","kind":{"type":"session"},"label":"Session",\
        "resetsAt":1700003600,"usedFraction":0.25},\
        {"detail":{"budget":"10","currency":"USD","kind":"money","spent":"15"},\
        "id":"additional:premium-requests:secondary:weekly",\
        "kind":{"name":"premium-requests","type":"named"},"label":"Premium requests",\
        "usedFraction":1.5}]}
        """

    private static let expectedHistoryJSON = """
        {"recordedAt":1700000060,"report":\(expectedReportJSON),"schemaVersion":1}
        """

    private static let expectedOutputJSON = """
        {"accounts":[{"label":"golden@example.com","report":\(expectedReportJSON)}],\
        "failures":[{"category":"rateLimited",\
        "message":"The provider returned HTTP 429.","providerID":"claude",\
        "retryAfterSeconds":30,"retryScope":"provider"}],\
        "generatedAt":1700000060,"schemaVersion":1}
        """

    private static let expectedAliasMapJSON = """
        {"aliases":[{"canonicalAccountID":"\(goldenAccountID)","providerID":"preview",\
        "recordedAt":1700000060,"retiredAccountID":"\(retiredAccountID)"}],"schemaVersion":1}
        """
}
