import Testing

@testable import Usage

/// The app's launch-argument gate.
///
/// Nothing here runs the probe: that is the operator's step under `docs/keychain-gate.md`, and it
/// has to be run against the app bundle's own identity rather than from a test host. What a test
/// can prove is that an ordinary launch is never mistaken for a diagnostic one, and that the UI
/// legs cannot be reached without asking for them.
@Suite("App keychain diagnostic")
struct KeychainDiagnosticTests {
    @Test("an ordinary launch is not a diagnostic run")
    func ignoresOrdinaryLaunches() {
        #expect(KeychainDiagnostic.invocation(from: []) == nil)
        #expect(KeychainDiagnostic.invocation(from: ["/Applications/Usage.app"]) == nil)
    }

    /// `--allow-ui` widens a gate run; it does not start one. Otherwise a stray flag on a normal
    /// launch would silently turn the menu bar app into a Keychain prompt.
    @Test("--allow-ui alone is not a way into the diagnostic")
    func requiresTheDiagnosticFlag() {
        #expect(KeychainDiagnostic.invocation(from: ["Usage", "--allow-ui"]) == nil)
    }

    @Test("the UI legs are off unless the launch asks for them")
    func gatesTheUILegsBehindTheirOwnFlag() {
        #expect(
            KeychainDiagnostic.invocation(from: ["Usage", "--diagnose-keychain"])
                == KeychainDiagnostic.Invocation(allowsUILegs: false)
        )
        #expect(
            KeychainDiagnostic.invocation(from: ["Usage", "--diagnose-keychain", "--allow-ui"])
                == KeychainDiagnostic.Invocation(allowsUILegs: true)
        )
    }

    @Test("the app reports under its own host label, separate from the CLI's")
    func reportsUnderItsOwnHost() {
        #expect(KeychainDiagnostic.host == "app")
    }
}
