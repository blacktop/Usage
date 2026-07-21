import Foundation

/// Read-only view of the agent-owned files a provider needs to discover accounts.
///
/// There is no write member by design: Usage never refreshes, rewrites, or copies an agent's
/// credential file, so the capability does not exist to be misused.
public protocol ProviderFileSystem: Sendable {
    var homeDirectory: URL { get }
    func fileExists(at url: URL) -> Bool
    func read(contentsOf url: URL) throws -> Data
    func contentsOfDirectory(at url: URL) throws -> [URL]
}
