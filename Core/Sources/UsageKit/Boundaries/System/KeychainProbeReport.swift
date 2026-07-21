import Foundation

/// Which interaction policy a probed leg ran under.
public enum KeychainProbePolicy: String, Sendable, Codable, CaseIterable {
    case noUI = "no-ui"
    case userInitiated = "user-initiated"

    public var allowsCredentialUI: Bool { self == .userInitiated }
}

/// Which query a probed leg issued.
public enum KeychainProbeLeg: String, Sendable, Codable, CaseIterable {
    case enumeration
    case payload
}

/// One measured leg.
///
/// The stored properties are the whole disclosure surface of the gate, and they are all
/// non-secret by construction: there is no field for an account name, a service attribute, a
/// persistent reference, a payload, or a payload length, so no output path can print one.
public struct KeychainProbeRow: Sendable, Codable, Equatable {
    public let host: String
    public let policy: KeychainProbePolicy
    public let leg: KeychainProbeLeg
    public let category: KeychainProbeCategory
    public let status: Int32
    public let itemCount: Int?

    public init(
        host: String,
        policy: KeychainProbePolicy,
        leg: KeychainProbeLeg,
        category: KeychainProbeCategory,
        status: Int32,
        itemCount: Int?
    ) {
        self.host = host
        self.policy = policy
        self.leg = leg
        self.category = category
        self.status = status
        self.itemCount = itemCount
    }
}

/// Everything one host's gate run measured.
public struct KeychainProbeRun: Sendable, Codable, Equatable {
    public let host: String
    public let didRunUILegs: Bool
    public let rows: [KeychainProbeRow]

    public init(host: String, didRunUILegs: Bool, rows: [KeychainProbeRow]) {
        self.host = host
        self.didRunUILegs = didRunUILegs
        self.rows = rows
    }
}

extension KeychainProbe {
    /// Runs the no-UI legs, then the user-initiated legs only when the caller asked for them.
    ///
    /// The no-UI enumeration always runs first, so the cheapest and quietest measurement is taken
    /// before anything that could conceivably prompt. With `allowsUILegs` false the run is
    /// structurally incapable of raising a dialog: every query it builds carries the no-UI markers.
    public func run(service: String, host: String, allowsUILegs: Bool) -> KeychainProbeRun {
        var rows = legs(service: service, host: host, policy: .noUI)
        if allowsUILegs {
            rows += legs(service: service, host: host, policy: .userInitiated)
        }
        return KeychainProbeRun(host: host, didRunUILegs: allowsUILegs, rows: rows)
    }

    private func legs(
        service: String,
        host: String,
        policy: KeychainProbePolicy
    ) -> [KeychainProbeRow] {
        let allowsUI = policy.allowsCredentialUI
        // One enumeration serves both legs: a second identical query would be a second chance to
        // prompt under the user-initiated policy, and the operator could not tell which leg did it.
        let enumerated = enumeration(service: service, allowsCredentialUI: allowsUI)
        let enumeration = enumerated.outcome
        let payload = payloadOutcome(after: enumerated, allowsCredentialUI: allowsUI)
        return [
            KeychainProbeRow(
                host: host,
                policy: policy,
                leg: .enumeration,
                category: enumeration.category,
                status: enumeration.status,
                itemCount: enumeration.itemCount
            ),
            KeychainProbeRow(
                host: host,
                policy: policy,
                leg: .payload,
                category: payload.category,
                status: payload.status,
                itemCount: nil
            ),
        ]
    }
}

/// Rendering for a gate run, shared by the CLI and the app so both hosts report identically.
///
/// An item count belongs to the enumeration leg only; the payload leg matches exactly one row by
/// reference, so a count there would be a constant pretending to be a measurement.
public enum KeychainProbeReport {
    private static let absent = "-"
    static let skippedUILegsNotice =
        "User-initiated legs skipped. Re-run with --allow-ui to include them."

    public static func table(_ run: KeychainProbeRun) -> String {
        var lines = TextTable.render(
            header: ["HOST", "POLICY", "LEG", "CATEGORY", "OSSTATUS", "ITEMS"],
            rows: run.rows.map(cells),
            alignment: [.leading, .leading, .leading, .leading, .trailing, .trailing]
        )
        if !run.didRunUILegs {
            if !lines.isEmpty { lines.append("") }
            lines.append(skippedUILegsNotice)
        }
        return lines.joined(separator: "\n")
    }

    /// The same run as JSON, for pasting into the gate's results document.
    public static func json(_ run: KeychainProbeRun) -> String {
        guard let data = try? UsageJSON.encoder().encode(run) else {
            return #"{"error":"The probe result could not be encoded."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func cells(_ row: KeychainProbeRow) -> [String] {
        [
            row.host,
            row.policy.rawValue,
            row.leg.rawValue,
            row.category.rawValue,
            String(row.status),
            row.itemCount.map(String.init) ?? absent,
        ]
    }
}
