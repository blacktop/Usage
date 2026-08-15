import Foundation
import Security
import Testing

@testable import UsageKit

/// The Keychain feasibility gate's probe, exercised without touching a real credential.
///
/// Nothing here calls `SecItemCopyMatching`. The probe's legs are the one thing that must be run
/// by a human operator under the protocol in `docs/keychain-gate.md`; what a test can prove is
/// that the queries those legs send are production's own, and that the results they hand back
/// structurally cannot carry a secret.
@Suite("Keychain probe")
struct KeychainProbeTests {
    private static let service = KeychainProbe.claudeService
    private static let reference = KeychainItemReference(data: Data([0x01, 0x02, 0x03]))

    /// A query reduced to comparable values.
    ///
    /// `LAContext` is not equatable and two policed queries hold different instances of it, so the
    /// marker is compared by its presence and type. Everything else is compared by value.
    private func signature(of query: [String: Any]) -> [String: String] {
        var described: [String: String] = [:]
        for (key, value) in query {
            switch value {
            case let string as String: described[key] = "string:\(string)"
            case let flag as Bool: described[key] = "bool:\(flag)"
            case let data as Data: described[key] = "data:\(data.base64EncodedString())"
            default: described[key] = "object:\(type(of: value))"
            }
        }
        return described
    }

    // MARK: - Query fidelity

    @Test(
        "the enumeration leg sends production's own query, under either policy",
        arguments: [false, true]
    )
    func enumerationQueryMatchesProduction(allowsCredentialUI: Bool) {
        let interaction: any InteractionPolicy =
            allowsCredentialUI ? UserInitiatedInteractionPolicy() : BackgroundInteractionPolicy()
        let production = KeychainCredentialSource(interaction: interaction)
            .policed(KeychainCredentialSource.enumerationQuery(service: Self.service))
        let probe = KeychainProbe.enumerationQuery(
            service: Self.service,
            allowsCredentialUI: allowsCredentialUI
        )
        #expect(signature(of: probe) == signature(of: production))
    }

    @Test(
        "the payload leg sends production's own query, under either policy",
        arguments: [false, true]
    )
    func payloadQueryMatchesProduction(allowsCredentialUI: Bool) {
        let interaction: any InteractionPolicy =
            allowsCredentialUI ? UserInitiatedInteractionPolicy() : BackgroundInteractionPolicy()
        let production = KeychainCredentialSource(interaction: interaction)
            .policed(KeychainCredentialSource.payloadQuery(reference: Self.reference))
        let probe = KeychainProbe.payloadQuery(
            reference: Self.reference,
            allowsCredentialUI: allowsCredentialUI
        )
        #expect(signature(of: probe) == signature(of: production))
    }

    @Test("the background leg carries both no-UI markers")
    func backgroundLegCannotPrompt() {
        for query in [
            KeychainProbe.enumerationQuery(service: Self.service, allowsCredentialUI: false),
            KeychainProbe.payloadQuery(reference: Self.reference, allowsCredentialUI: false),
        ] {
            #expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF")
            #expect(query[kSecUseAuthenticationContext as String] != nil)
        }
    }

    /// The user-initiated leg is the only construction that can raise a dialog, which is exactly
    /// what the gate's second half is measuring. A probe that kept the markers here would report
    /// the no-UI result twice and call it two measurements.
    @Test("the user-initiated leg drops both no-UI markers")
    func userInitiatedLegIsTheOneThatCanPrompt() {
        for query in [
            KeychainProbe.enumerationQuery(service: Self.service, allowsCredentialUI: true),
            KeychainProbe.payloadQuery(reference: Self.reference, allowsCredentialUI: true),
        ] {
            #expect(query[kSecUseAuthenticationUI as String] == nil)
            #expect(query[kSecUseAuthenticationContext as String] == nil)
        }
    }

    @Test("the enumeration query still cannot return a secret, probe or not")
    func enumerationLegNeverAsksForData() {
        let query = KeychainProbe.enumerationQuery(
            service: Self.service,
            allowsCredentialUI: true
        )
        #expect(query[kSecReturnData as String] == nil)
        #expect(query[kSecReturnAttributes as String] as? Bool == true)
    }

    // MARK: - Status mapping

    @Test(
        "each status the gate distinguishes maps to its own category",
        arguments: [
            (errSecSuccess, KeychainProbeCategory.success),
            (errSecItemNotFound, .itemNotFound),
            (errSecInteractionNotAllowed, .interactionNotAllowed),
            (errSecAuthFailed, .authFailed),
            (errSecUserCanceled, .userCanceled),
        ]
    )
    func mapsKnownStatuses(status: OSStatus, expected: KeychainProbeCategory) {
        #expect(KeychainProbeCategory(status: status) == expected)
    }

    @Test("an unmapped status is `other`, and its number survives intact")
    func preservesUnmappedStatuses() {
        let unmapped: OSStatus = -34_018
        #expect(KeychainProbeCategory(status: unmapped) == .other)

        let enumeration = KeychainEnumerationOutcome(status: unmapped, itemCount: 0)
        #expect(enumeration.category == .other)
        #expect(enumeration.status == unmapped)

        let payload = KeychainPayloadOutcome(
            status: unmapped,
            didReadPayload: true,
            isPayloadPresent: false
        )
        #expect(payload.category == .other)
        #expect(payload.status == unmapped)
    }

    // MARK: - Redaction by construction

    /// A byte count is still information about a secret, so there is no field that could hold one.
    @Test("the payload outcome has no field a secret or its length could live in")
    func payloadOutcomeCannotCarryASecret() {
        let outcome = KeychainPayloadOutcome(
            status: errSecSuccess,
            didReadPayload: true,
            isPayloadPresent: true
        )
        let stored = Mirror(reflecting: outcome).children.compactMap(\.label)
        #expect(stored == ["status", "didReadPayload", "isPayloadPresent"])
    }

    @Test("the payload outcome's encoded form is three scalars and nothing else")
    func payloadOutcomeEncodesWithoutPayloadDerivedFields() throws {
        let encoded = try Fixtures.encodedString(
            KeychainPayloadOutcome(
                status: errSecSuccess,
                didReadPayload: true,
                isPayloadPresent: true
            )
        )
        #expect(encoded == #"{"didReadPayload":true,"isPayloadPresent":true,"status":0}"#)
    }

    @Test("a reported row has no field for an account, a service, or a row reference")
    func rowCannotCarryAnIdentifier() {
        let stored = Mirror(reflecting: Self.row(leg: .enumeration, itemCount: 2))
            .children.compactMap(\.label)
        #expect(stored == ["host", "policy", "leg", "category", "status", "itemCount"])
    }

    @Test("the enumeration outcome reports a count and nothing that identifies a row")
    func enumerationOutcomeReportsOnlyACount() {
        let stored = Mirror(reflecting: KeychainEnumerationOutcome(status: 0, itemCount: 3))
            .children.compactMap(\.label)
        #expect(stored == ["status", "itemCount"])
    }

    // MARK: - Rendering

    @Test("the table reports one row per leg, with a count only on the enumeration leg")
    func rendersOneRowPerLeg() {
        let table = KeychainProbeReport.table(
            KeychainProbeRun(
                host: "cli",
                didRunUILegs: true,
                rows: [
                    Self.row(leg: .enumeration, itemCount: 2),
                    Self.row(leg: .payload, itemCount: nil),
                ]
            )
        )
        let lines = table.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("HOST"))
        #expect(lines[1].contains("enumeration"))
        #expect(lines[1].hasSuffix("2"))
        #expect(lines[2].contains("payload"))
        #expect(lines[2].hasSuffix("-"))
        #expect(!table.contains(KeychainProbeReport.skippedUILegsNotice))
    }

    @Test("a run without the UI legs says so, rather than reading as a complete gate")
    func announcesSkippedUILegs() {
        let table = KeychainProbeReport.table(
            KeychainProbeRun(
                host: "cli",
                didRunUILegs: false,
                rows: [Self.row(leg: .enumeration, itemCount: 0)]
            )
        )
        #expect(table.contains(KeychainProbeReport.skippedUILegsNotice))
        #expect(table.contains("--allow-ui"))
    }

    @Test("the JSON form carries the same non-secret fields and no others")
    func encodesTheRun() throws {
        let encoded = KeychainProbeReport.json(
            KeychainProbeRun(
                host: "cli",
                didRunUILegs: false,
                rows: [Self.row(leg: .enumeration, itemCount: 0)]
            )
        )
        #expect(
            encoded == #"{"didRunUILegs":false,"host":"cli","rows":"#
                + #"[{"category":"interactionNotAllowed","host":"cli","itemCount":0,"#
                + #""leg":"enumeration","policy":"no-ui","status":-25308}]}"#
        )
    }

    // MARK: - Scope

    /// The probe is a gate instrument, not a boundary. If a refresh, discovery, or provider path
    /// ever reaches for it, the production read has grown a second shape and the gate stops
    /// measuring what ships.
    @Test("no production path outside the gate's own files mentions the probe")
    func probeIsReachableOnlyFromTheGate() throws {
        let allowed: Set<String> = [
            "KeychainProbe.swift",
            "KeychainProbeReport.swift",
            "KeychainDiagnoseCommand.swift",
            "KeychainDiagnostic.swift",
            // Gate A of the Claude metering plan: its enumeration-only leg is deliberately the
            // probe's production-shaped query, run per derived root service.
            "ClaudeGateDiagnostics.swift",
        ]
        var scanned = 0
        var offenders: [String] = []
        for root in ["Core/Sources", "App"] {
            let base = Self.repositoryRoot.appending(path: root, directoryHint: .isDirectory)
            for url in try Self.swiftFiles(in: base) {
                scanned += 1
                guard !allowed.contains(url.lastPathComponent) else { continue }
                let source = try String(contentsOf: url, encoding: .utf8)
                if source.contains("KeychainProbe") { offenders.append(url.lastPathComponent) }
            }
        }
        #expect(scanned > 0, "the source roots were not found, so nothing was actually checked")
        #expect(offenders == [])
    }

    private static var repositoryRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // Boundaries
            .deletingLastPathComponent()  // UsageKitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Core
            .deletingLastPathComponent()  // repository root
    }

    private static func swiftFiles(in directory: URL) throws -> [URL] {
        guard
            let walker = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return [] }
        var found: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            found.append(url)
        }
        return found
    }

    private static func row(leg: KeychainProbeLeg, itemCount: Int?) -> KeychainProbeRow {
        KeychainProbeRow(
            host: "cli",
            policy: .noUI,
            leg: leg,
            category: .interactionNotAllowed,
            status: errSecInteractionNotAllowed,
            itemCount: itemCount
        )
    }
}
