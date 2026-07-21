import Foundation
import Synchronization

/// In-memory `ProviderFileSystem` seeded with fixture files.
///
/// Records every read so a test can prove which credential paths a provider touched — and, more
/// usefully, which it did not.
public final class InMemoryFileSystem: ProviderFileSystem, Sendable {
    private struct State {
        var files: [URL: Data]
        var reads: [URL] = []
    }

    private let state: Mutex<State>
    public let homeDirectory: URL

    public init(homeDirectory: URL = URL(filePath: "/Users/preview"), files: [URL: Data] = [:]) {
        self.homeDirectory = homeDirectory
        state = Mutex(State(files: files))
    }

    /// URLs the provider actually read, in call order.
    public var recordedReads: [URL] {
        state.withLock { $0.reads }
    }

    public func fileExists(at url: URL) -> Bool {
        state.withLock { $0.files[url.standardizedFileURL] != nil }
    }

    public func read(contentsOf url: URL) throws -> Data {
        try state.withLock { state throws(UsageError) -> Data in
            state.reads.append(url)
            guard let data = state.files[url.standardizedFileURL] else {
                throw UsageError.credentialUnavailable(kind: .file)
            }
            return data
        }
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        let directory = Self.directoryPath(of: url)
        return state.withLock { state in
            state.files.keys
                .filter { Self.directoryPath(of: $0.deletingLastPathComponent()) == directory }
                .sorted { $0.absoluteString < $1.absoluteString }
        }
    }

    private static func directoryPath(of url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }
}
