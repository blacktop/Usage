import ArgumentParser
import Foundation
import UsageKit

/// The `--provider` selection shared by every subcommand.
struct ProviderSelection: ParsableArguments {
    @Option(
        name: .customLong("provider"),
        parsing: .singleValue,
        help: "Provider to report on. Repeat for several. Defaults to every provider."
    )
    var providers: [String] = []

    /// Selected identifiers, or a validation error naming every unknown one at once.
    func resolved(in registry: ProviderRegistry) throws -> [ProviderID] {
        do {
            return try registry.resolve(providers)
        } catch {
            let known = registry.providerIDs.map(\.rawValue).joined(separator: ", ")
            throw ValidationError(
                "Unknown provider \(error.names.joined(separator: ", ")). Known: \(known)."
            )
        }
    }
}

/// Shared body of every reporting subcommand.
///
/// Usage is read-only in the CLI by construction: nothing here writes history, the latest-snapshot
/// cache, the identity alias map, notification state, or a credential. The exit status is the
/// collection's own outcome, so a partial answer is distinguishable from a total failure without
/// parsing the output.
enum ReportRunner {
    static func run(
        selection: ProviderSelection,
        render: (UsageCollection, Date) -> String
    ) async throws {
        try await run(
            selection: selection,
            registry: .commandLine,
            context: .system(),
            render: render
        )
    }

    /// The whole command, with the registry and every boundary injected, so a test can drive it
    /// without a credential, a network, or a real clock.
    static func run(
        selection: ProviderSelection,
        registry: ProviderRegistry,
        context: ProviderContext,
        render: (UsageCollection, Date) -> String
    ) async throws {
        let requested = try selection.resolved(in: registry)
        let collection = await UsageCollector(registry: registry)
            .collect(providers: requested, using: context)
        print(render(collection, context.clock.now))
        if let code = exitCode(for: collection) { throw code }
    }

    /// The process status for a finished run, or `nil` when every requested provider answered.
    ///
    /// Split out because it is the contract a status line consumes: `0` complete, `2` partial,
    /// `1` nothing answered.
    static func exitCode(for collection: UsageCollection) -> ExitCode? {
        let outcome = collection.outcome
        guard outcome != .complete else { return nil }
        return ExitCode(outcome.rawValue)
    }
}
