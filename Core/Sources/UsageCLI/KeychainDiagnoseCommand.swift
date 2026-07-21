import ArgumentParser
import UsageKit

/// `usage diagnose keychain` — the CLI half of the Keychain feasibility gate.
///
/// Keychain access is a per-host capability, so the standalone CLI and the app bundle have to be
/// measured as separate hosts; this command answers for the CLI only.
///
/// Two flags gate the two ways this could go wrong. Without `--allow-any-service` it refuses to
/// probe anything but the Claude Code credential service, so the gate cannot quietly widen into a
/// Keychain survey. Without `--allow-ui` every query it builds carries the no-UI markers, so it is
/// structurally incapable of raising a dialog.
struct KeychainDiagnoseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keychain",
        abstract: "Probe this host's Keychain access and print redacted outcomes.",
        discussion: """
            Runs the no-UI enumeration leg first, then the no-UI payload leg. Every value read is \
            discarded at the read: the output carries a host, a policy, a leg, an outcome \
            category, an OSStatus, and an item count, and never an account name, a service \
            attribute, a persistent reference, a payload, or a payload length.

            Exits 0 whenever the probe ran. An errSecInteractionNotAllowed is a successful \
            measurement, not a failure of this command.
            """
    )

    /// The host label this command reports under. The app reports under its own.
    static let host = "cli"

    @Option(name: .customLong("service"), help: "Keychain service to probe.")
    var service: String = KeychainProbe.claudeService

    @Flag(
        name: .customLong("allow-any-service"),
        help: "Permit a service other than the Claude Code credential service."
    )
    var allowAnyService = false

    @Flag(
        name: .customLong("allow-ui"),
        help: "Also run the user-initiated legs. These are the only ones that can prompt."
    )
    var allowUI = false

    @Flag(name: .customLong("json"), help: "Emit the run as JSON instead of a table.")
    var json = false

    /// The gate is scoped to one service, and this enforces the scope rather than trusting the
    /// operator to retype it correctly. The rejected value is not echoed back.
    func validate() throws {
        guard allowAnyService || service == KeychainProbe.claudeService else {
            throw ValidationError(
                "This gate is scoped to the Claude Code credential service. "
                    + "Pass --allow-any-service to probe a different one."
            )
        }
    }

    func run() throws {
        let measured = KeychainProbe()
            .run(service: service, host: Self.host, allowsUILegs: allowUI)
        print(json ? KeychainProbeReport.json(measured) : KeychainProbeReport.table(measured))
    }
}
