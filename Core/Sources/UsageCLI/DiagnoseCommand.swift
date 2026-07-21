import ArgumentParser

/// Host capability probes.
///
/// Separate from the reporting commands because nothing here reports usage: these measure what
/// this host is allowed to do, and they read no account.
struct DiagnoseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnose",
        abstract: "Measure this host's access to a credential store.",
        subcommands: [KeychainDiagnoseCommand.self]
    )
}
