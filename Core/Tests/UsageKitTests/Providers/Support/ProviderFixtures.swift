import Foundation
import Testing

@testable import UsageKit

/// Loads the sanitized provider fixtures checked in beside these tests.
enum ProviderFixtures {
    static let home = URL(filePath: "/Users/fixture", directoryHint: .isDirectory)

    /// A configuration root below the fixture home.
    ///
    /// The three named roots below are the ones `ProfileRootCollection.seeded` produces for this
    /// home, so a context that takes the default root store discovers exactly these directories.
    static func root(_ path: String) -> URL {
        home.appending(path: path, directoryHint: .isDirectory)
    }

    static let claudeRoot = root(".claude")
    static let codexRoot = root(".codex")
    static let copilotRoot = root(".copilot")

    static func data(_ provider: String, _ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "Fixtures/\(provider)"
            ),
            "Missing fixture Fixtures/\(provider)/\(name).json"
        )
        return try Data(contentsOf: url)
    }

    static func response(
        _ provider: String,
        _ name: String,
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "application/json"]
    ) throws -> HTTPResponse {
        HTTPResponse(status: status, headers: headers, body: try data(provider, name))
    }

    /// Directories every checked-in fixture lives in.
    static let providerDirectories = ["Claude", "Codex", "Copilot"]

    /// Prefixes that only ever introduce credential material in a fixture.
    ///
    /// `fake-model-a` and friends are deliberately not here: they are display labels a report is
    /// supposed to carry, and listing them would make the redaction suite assert the opposite of
    /// what it means.
    static let secretPrefixes = [
        "FAKE-access", "FAKE-refresh", "FAKE-sk", "sk-ant-", "gho_", "fake-mcp-",
    ]

    /// Strings that only ever appear inside fixture credentials or fixture error bodies.
    ///
    /// Nothing Usage renders, encodes, or logs may contain any of them. Kept exhaustive by
    /// `everySecretShapedFixtureValueIsListed`, because a list that silently misses a token turns
    /// the whole redaction suite into a test that cannot fail.
    static let secretShapedValues = [
        "FAKE-access-token-0000",
        "FAKE-refresh-token-0000",
        "FAKE-sk-proj-AAAABBBBCCCCDDDD",
        "FAKE-sk-test",
        "sk-ant-oat01-FAKE-ACCESS-TOKEN-DO-NOT-USE-0000000000",
        "sk-ant-ort01-FAKE-REFRESH-TOKEN-DO-NOT-USE-000000000",
        "sk-ant-oat01-FAKE-EXPIRED-TOKEN-0000000000000000000",
        "sk-ant-ort01-FAKE-EXPIRED-REFRESH-000000000000000000",
        "fake-mcp-token-0000000000",
        "gho_FIXTURE0000000000000000000000000001",
        "gho_FIXTURE0000000000000000000000000002",
        "gho_FIXTURE0000000000000000000000000003",
        "gho_FIXTURE0000000000000000000000000004",
        "gho_FIXTURE0000000000000000000000000005",
        "gho_FIXTURE0000000000000000000000000006",
        "gho_FIXTURE0000000000000000000000000007",
        "gho_FIXTURE0000000000000000000000000008",
        "Bearer ",
    ]

    /// Every token-shaped string present in any checked-in fixture, found by scanning rather than
    /// by remembering.
    static func scannedSecretShapedValues() throws -> Set<String> {
        var found: Set<String> = []
        for directory in providerDirectories {
            let urls =
                Bundle.module.urls(
                    forResourcesWithExtension: "json",
                    subdirectory: "Fixtures/\(directory)"
                ) ?? []
            #expect(!urls.isEmpty, "no fixtures found under Fixtures/\(directory)")
            for url in urls {
                let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
                found.formUnion(tokenRuns(in: text).filter(isSecretShaped))
            }
        }
        return found
    }

    private static func isSecretShaped(_ value: String) -> Bool {
        secretPrefixes.contains { value.hasPrefix($0) }
    }

    /// Every maximal run of token characters, so a token embedded in an error message is found as
    /// readily as one that is a whole JSON scalar.
    private static func tokenRuns(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            guard character.isLetter || character.isNumber || character == "-" || character == "_"
            else {
                if !current.isEmpty { result.append(current) }
                current = ""
                continue
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
