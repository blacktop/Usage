import ArgumentParser
import UsageKit

@main
struct UsageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage",
        abstract: "Report AI agent account usage.",
        version: UsageKitInfo.version,
        subcommands: [ListCommand.self, JSONCommand.self, DiagnoseCommand.self],
        defaultSubcommand: ListCommand.self
    )
}
