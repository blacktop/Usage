import ArgumentParser
import UsageKit

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "Print a table of every window each account is burning."
    )

    @OptionGroup var selection: ProviderSelection

    func run() async throws {
        try await ReportRunner.run(selection: selection) { collection, now in
            UsageTable.render(collection, now: now)
        }
    }
}
