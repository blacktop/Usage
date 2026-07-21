import ArgumentParser
import Foundation
import Testing
import UsageKit

@testable import UsageCLI

/// The CLI's own contract: which provider names it accepts, and the exit status it reports.
///
/// Both are consumed by things that never read the output — a shell `if`, a status line — so a
/// silent change here is a change nobody sees until it is wrong.
@Suite("CLI report runner")
struct ReportRunnerTests {
    private static let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func collection(accounts: Int, failures: Int) throws -> UsageCollection {
        let provider = ProviderID("codex")
        let report = try UsageReport(
            accountKey: AccountKey(
                providerID: provider,
                accountID: .canonical(provider: provider, canonicalID: "one")
            ),
            plan: "pro",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: 0.5
                )
            ],
            capturedAt: Self.now
        )
        return UsageCollection(
            requested: [provider],
            accounts: (0..<accounts).map { _ in
                CollectedAccount(
                    account: ProviderAccount(
                        key: report.accountKey,
                        slot: CredentialSlotID(source: "test", opaqueID: "one"),
                        locator: CredentialLocator(kind: .file, identifier: "/dev/null")
                    ),
                    report: report
                )
            },
            failures: (0..<failures).map { _ in
                CollectedFailure(
                    providerID: provider,
                    accountID: nil,
                    error: .transportFailure()
                )
            }
        )
    }

    @Test("a complete run reports success by not throwing at all")
    func completeRunExitsZero() throws {
        #expect(ReportRunner.exitCode(for: try collection(accounts: 1, failures: 0)) == nil)
    }

    @Test("a partial run exits 2 so a status line can tell it from a clean run")
    func partialRunExitsTwo() throws {
        #expect(ReportRunner.exitCode(for: try collection(accounts: 1, failures: 1)) == ExitCode(2))
    }

    @Test("a run in which nothing answered exits 1")
    func totalFailureExitsOne() throws {
        #expect(ReportRunner.exitCode(for: try collection(accounts: 0, failures: 1)) == ExitCode(1))
    }

    @Test("an unknown provider name is a validation error naming every registered provider")
    func unknownProviderIsAValidationError() throws {
        let selection = try ProviderSelection.parse([
            "--provider", "gemini", "--provider", "cursor",
        ])

        var captured: String?
        do {
            _ = try selection.resolved(in: .commandLine)
        } catch let error as ValidationError {
            captured = "\(error)"
        }

        let message = try #require(captured, "an unknown name must not reach a provider")
        #expect(message.contains("gemini"))
        #expect(message.contains("cursor"))
        #expect(message.contains("codex"))
    }

    @Test("no argument means every provider the CLI is allowed to run")
    func emptySelectionResolvesToTheCommandLineRegistry() throws {
        #expect(
            try ProviderSelection.parse([]).resolved(in: .commandLine).map(\.rawValue)
                == ProviderRegistry.commandLine.providerIDs.map(\.rawValue)
        )
    }

    /// Every account now comes from a configured root and every credential from a file below it,
    /// so there is no per-host capability left for the CLI's registry to differ over.
    @Test("the CLI registry holds every implemented provider")
    func commandLineRegistryHoldsEveryProvider() {
        #expect(
            ProviderRegistry.commandLine.providerIDs.map(\.rawValue).sorted()
                == ["claude", "codex", "copilot"]
        )
        #expect(
            ProviderRegistry.commandLine.providerIDs == ProviderRegistry.agents.providerIDs,
            "the CLI runs exactly what is implemented"
        )
    }

    /// The injected file system holds none of the documents the seeded roots name, so every
    /// registered provider discovers nothing and reports itself unavailable.
    @Test("a run that reaches no provider at all still prints and still exits 1")
    func runReportsATotalFailure() async throws {
        let selection = try ProviderSelection.parse([])
        let context = ProviderContext(
            http: InMemoryHTTPTransport(),
            credentials: InMemoryCredentialSource(),
            fileSystem: InMemoryFileSystem(),
            clock: ManualClock(now: Self.now),
            interaction: BackgroundInteractionPolicy()
        )
        var rendered: String?

        await #expect(throws: ExitCode(1)) {
            try await ReportRunner.run(
                selection: selection,
                registry: .commandLine,
                context: context
            ) { collection, _ in
                rendered = "\(collection.accounts.count)/\(collection.failures.count)"
                return ""
            }
        }
        #expect(rendered == "0/3")
    }
}
