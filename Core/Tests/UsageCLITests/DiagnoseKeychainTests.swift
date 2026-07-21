import ArgumentParser
import Testing
import UsageKit

@testable import UsageCLI

/// The CLI gate command's flag discipline.
///
/// Nothing here runs the probe: `run()` issues a real `SecItemCopyMatching`, which is the
/// operator's step under `docs/keychain-gate.md`. What a test can prove is that the command cannot
/// be talked into a wider scope or into prompting by accident.
@Suite("CLI keychain diagnostic")
struct DiagnoseKeychainTests {
    private func message(parsing arguments: [String]) -> String? {
        do {
            _ = try KeychainDiagnoseCommand.parse(arguments)
            return nil
        } catch {
            return KeychainDiagnoseCommand.message(for: error)
        }
    }

    @Test("the gate is reachable as `usage diagnose keychain`")
    func isRegisteredAsASubcommand() {
        #expect(UsageCommand.configuration.subcommands.contains { $0 == DiagnoseCommand.self })
        #expect(
            DiagnoseCommand.configuration.subcommands
                .contains { $0 == KeychainDiagnoseCommand.self }
        )
    }

    @Test("no argument means the one service the gate is scoped to, and no UI")
    func defaultsToTheClaudeServiceWithoutUI() throws {
        let command = try KeychainDiagnoseCommand.parse([])
        #expect(command.service == KeychainProbe.claudeService)
        #expect(command.allowAnyService == false)
        #expect(command.allowUI == false)
        #expect(command.json == false)
    }

    @Test("another service is refused, and the refusal does not echo it back")
    func refusesForeignServicesByDefault() throws {
        let refusal = try #require(message(parsing: ["--service", "Codex Auth"]))
        #expect(refusal.contains("--allow-any-service"))
        #expect(!refusal.contains("Codex Auth"))
    }

    @Test("widening the scope is possible, but only by asking for it")
    func acceptsAnyServiceWhenAsked() throws {
        let command = try KeychainDiagnoseCommand.parse([
            "--service", "Codex Auth", "--allow-any-service",
        ])
        #expect(command.service == "Codex Auth")
    }

    @Test("the UI legs need their own flag")
    func requiresAnExplicitFlagForUILegs() throws {
        #expect(try KeychainDiagnoseCommand.parse(["--allow-ui"]).allowUI)
    }

    /// The flag's absence has to be visible in the output, otherwise a half-run gate reads exactly
    /// like a complete one in the results document.
    @Test("a run without the UI legs reports that they were skipped and how to enable them")
    func reportsSkippedUILegs() {
        let table = KeychainProbeReport.table(
            KeychainProbeRun(host: KeychainDiagnoseCommand.host, didRunUILegs: false, rows: [])
        )
        #expect(table.contains("--allow-ui"))
    }

    @Test("the CLI reports under its own host label, separate from the app's")
    func reportsUnderItsOwnHost() {
        #expect(KeychainDiagnoseCommand.host == "cli")
    }
}
