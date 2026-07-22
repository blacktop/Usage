import Foundation

/// One atomically replaced, versioned JSON document below the app's writer lease.
public struct AtomicJSONFile<Value: Codable & Sendable>: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public func load(fileManager: FileManager = .default) throws -> Value? {
        guard fileManager.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try UsageJSON.decoder().decode(Value.self, from: data)
        } catch {
            throw UsagePersistenceError.unavailable(operation: "read JSON state")
        }
    }

    public func save(
        _ value: Value,
        holding lease: UsageWriterLease,
        fileManager: FileManager = .default
    ) throws {
        guard lease.covers(url) else { throw UsagePersistenceError.writerLeaseRequired }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try UsageJSON.encoder().encode(value)
            try data.write(to: url, options: .atomic)
        } catch let error as UsagePersistenceError {
            throw error
        } catch {
            throw UsagePersistenceError.unavailable(operation: "write JSON state")
        }
    }
}
