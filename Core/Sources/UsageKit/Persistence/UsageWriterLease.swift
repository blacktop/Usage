import Darwin
import Foundation

/// The process-lifetime capability required for app-owned durable writes.
///
/// Acquisition is non-blocking. A second app process receives `nil` rather than waiting and later
/// becoming a surprise writer. Releasing the final reference closes the descriptor and transfers
/// ownership cleanly even when the process exits without running application shutdown code.
public final class UsageWriterLease: @unchecked Sendable {
    private let descriptor: Int32
    private let rootDirectory: URL

    private init(descriptor: Int32, rootDirectory: URL) {
        self.descriptor = descriptor
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    public static func acquire(
        paths: UsagePersistencePaths,
        fileManager: FileManager = .default
    ) throws -> UsageWriterLease? {
        do {
            try fileManager.createDirectory(
                at: paths.rootDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw UsagePersistenceError.unavailable(operation: "create persistence directory")
        }

        let path = paths.writerLock.path(percentEncoded: false)
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw UsagePersistenceError.unavailable(operation: "open writer lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
            throw UsagePersistenceError.unavailable(operation: "acquire writer lock")
        }
        return UsageWriterLease(descriptor: descriptor, rootDirectory: paths.rootDirectory)
    }

    func covers(_ file: URL) -> Bool {
        let rootComponents = rootDirectory.standardizedFileURL.pathComponents
        let fileComponents = file.standardizedFileURL.pathComponents
        return fileComponents.count > rootComponents.count
            && fileComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }
}
