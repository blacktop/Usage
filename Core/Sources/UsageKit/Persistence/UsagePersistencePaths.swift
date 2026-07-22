import Foundation

/// The app-owned files below Application Support.
///
/// A root can be injected for tests. Production resolves the user-domain Application Support
/// directory without consulting shell state, then keeps every mutable artifact below `Usage`.
public struct UsagePersistencePaths: Sendable, Hashable {
    public let rootDirectory: URL

    public init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    public static func system(fileManager: FileManager = .default) throws -> Self {
        guard
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw UsagePersistenceError.unavailable(operation: "locate application support")
        }
        return Self(
            rootDirectory: applicationSupport.appending(path: "Usage", directoryHint: .isDirectory))
    }

    public var writerLock: URL { rootDirectory.appending(path: ".writer.lock") }
    public var identityAliases: URL {
        rootDirectory.appending(path: "identity-aliases-v1.json")
    }
    public var notificationState: URL {
        rootDirectory.appending(path: "notification-state-v1.json")
    }
}

public enum UsagePersistenceError: Error, Sendable, Hashable {
    case unavailable(operation: String)
    case writerLeaseRequired
}
