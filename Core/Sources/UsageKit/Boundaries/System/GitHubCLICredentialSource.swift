import Foundation

/// Runs the GitHub CLI without a shell, returning only its standard output.
///
/// The production implementation fixes the executable and subcommand in
/// `GitHubCLICredentialSource`. Its only discovered argument is a validated, single-line public
/// login passed directly to `Process`, never through a shell. Standard error is discarded so the
/// CLI cannot leak credential diagnostics into Usage logs.
protocol GitHubCLICommandRunning: Sendable {
    func run(arguments: [String]) throws(UsageError) -> Data
}

struct SystemGitHubCLICommandRunner: GitHubCLICommandRunning {
    private static let executableCandidates = [
        URL(filePath: "/opt/homebrew/bin/gh"),
        URL(filePath: "/usr/local/bin/gh"),
    ]

    func run(arguments: [String]) throws(UsageError) -> Data {
        guard
            let executable = Self.executableCandidates.first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false))
            })
        else {
            throw UsageError.credentialUnavailable(kind: .githubCLI)
        }

        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = try output.fileHandleForReading.readToEnd() ?? Data()
            process.waitUntilExit()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw UsageError.credentialUnavailable(kind: .githubCLI)
            }
            return data
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.credentialUnavailable(kind: .githubCLI)
        }
    }
}

/// Resolves one explicitly named GitHub CLI account exactly as `gh` does.
///
/// Account discovery enumerates GitHub CLI's Keychain attributes through `KeychainCredentialSource`
/// and constructs one account-bound locator per public login. This source is fetch-only: it never
/// runs `gh auth status`, so discovery remains local and offline. Token output is requested only
/// inside `withCredential`, remains operation-scoped, and is never logged or retained.
struct GitHubCLICredentialSource: CredentialSource {
    static let host = "github.com"

    private let runner: any GitHubCLICommandRunning

    init(runner: any GitHubCLICommandRunning = SystemGitHubCLICommandRunner()) {
        self.runner = runner
    }

    static func locator(host: String = host, login: String) -> CredentialLocator? {
        guard host == Self.host, let login = singleLine(login) else { return nil }
        return CredentialLocator(kind: .githubCLI, identifier: host, path: [login])
    }

    func withCredential<T: CredentialScopedResult>(
        at locator: CredentialLocator,
        perform operation: (Credential) async throws -> T
    ) async throws -> T {
        guard locator.kind == .githubCLI, locator.identifier == Self.host,
            locator.path.count == 1, let login = locator.path.first.flatMap(Self.singleLine)
        else {
            throw UsageError.credentialUnavailable(kind: locator.kind)
        }
        let output = try runner.run(arguments: Self.tokenArguments(login: login))
        guard let token = String(data: output, encoding: .utf8)?.trimmedNonEmpty else {
            throw UsageError.credentialUnavailable(kind: .githubCLI)
        }
        return try await operation(Credential(secret: token))
    }

    static func tokenArguments(login: String) -> [String] {
        ["auth", "token", "--hostname", host, "--user", login]
    }

    private static func singleLine(_ value: String) -> String? {
        guard let trimmed = value.trimmedNonEmpty,
            !trimmed.unicodeScalars.contains(where: CharacterSet.newlines.contains)
        else { return nil }
        return trimmed
    }
}
