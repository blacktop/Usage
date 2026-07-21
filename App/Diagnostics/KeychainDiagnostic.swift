import Foundation
import UsageKit
import os

/// The app half of the Keychain feasibility gate: `Usage --diagnose-keychain [--allow-ui]`.
///
/// Keychain access is a per-host capability and an ad-hoc re-signature invalidates an item's ACL,
/// so the app bundle has to be measured separately from the CLI and again after every rebuild. A
/// launch argument is the only way to reach the app bundle's own identity, which is the thing being
/// measured — running the same probe from a test bundle or the CLI would answer for a different
/// host.
///
/// A diagnostic launch installs no `MenuBarExtra`, constructs no `AppModel`, starts no
/// `RefreshCoordinator`, and performs no network work: `UsageApp` short-circuits before any of them
/// exist.
enum KeychainDiagnostic {
    /// The host label this bundle reports under. The CLI reports under its own.
    static let host = "app"

    private static let diagnoseFlag = "--diagnose-keychain"
    private static let allowUIFlag = "--allow-ui"
    private static let logger = Logger(subsystem: "dev.blacktop.Usage", category: "keychain-gate")

    struct Invocation: Equatable {
        var allowsUILegs: Bool
    }

    /// The diagnostic run `arguments` asks for, or `nil` for an ordinary launch.
    ///
    /// `--allow-ui` alone is not a diagnostic launch: the UI legs are an addition to the gate, not
    /// a way into it.
    static func invocation(from arguments: [String]) -> Invocation? {
        guard arguments.contains(diagnoseFlag) else { return nil }
        return Invocation(allowsUILegs: arguments.contains(allowUIFlag))
    }

    /// Runs the probe against the Claude service and writes the table to stdout and the log.
    ///
    /// The unified log copy is what survives a run started by LaunchServices rather than a
    /// terminal, where stdout goes nowhere a person can read it.
    static func run(_ invocation: Invocation) {
        let table = KeychainProbeReport.table(
            KeychainProbe().run(
                service: KeychainProbe.claudeService,
                host: host,
                allowsUILegs: invocation.allowsUILegs
            )
        )
        print(table)
        logger.notice("keychain-gate host=\(host, privacy: .public)\n\(table, privacy: .public)")
    }
}
