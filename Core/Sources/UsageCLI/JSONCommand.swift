import ArgumentParser
import Foundation
import UsageKit

struct JSONCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "json",
        abstract: "Print the versioned UsageOutputV1 envelope."
    )

    @OptionGroup var selection: ProviderSelection

    func run() async throws {
        try await ReportRunner.run(selection: selection) { collection, now in
            Self.encode(collection.output(generatedAt: now))
        }
    }

    /// An envelope that cannot be encoded is reported as a one-line JSON object rather than as a
    /// crash, so a status line consuming this command always receives parseable output.
    private static func encode(_ output: UsageOutputV1) -> String {
        guard let data = try? UsageJSON.encoder().encode(output) else {
            return #"{"schemaVersion":1,"error":"The report could not be encoded."}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
