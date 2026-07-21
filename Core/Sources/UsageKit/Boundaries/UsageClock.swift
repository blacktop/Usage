import Foundation

/// The time boundary. Nothing above it reads the wall clock directly, so schedules and reset
/// countdowns are deterministic under test.
public protocol UsageClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

/// The production clock.
public struct SystemClock: UsageClock {
    public init() {}

    public var now: Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
