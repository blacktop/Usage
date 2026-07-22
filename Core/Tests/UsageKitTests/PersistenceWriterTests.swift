import Foundation
import Testing

@testable import UsageKit

@Suite("Persistence writer")
struct PersistenceWriterTests {
    @Test("Exactly one lease owns a persistence root and ownership transfers on release")
    func writerLeaseIsExclusive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var first = try UsageWriterLease.acquire(paths: fixture.paths)

        #expect(first != nil)
        #expect(try UsageWriterLease.acquire(paths: fixture.paths) == nil)
        first = nil

        let next = try UsageWriterLease.acquire(paths: fixture.paths)
        #expect(next != nil)
    }

    @Test("Atomic JSON requires a lease covering the destination")
    func writerLeaseIsPathScoped() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer {
            first.remove()
            second.remove()
        }
        let acquired = try UsageWriterLease.acquire(paths: first.paths)
        let lease = try #require(acquired)
        let file = AtomicJSONFile<IdentityAliasMapV1>(url: second.paths.identityAliases)

        #expect(throws: UsagePersistenceError.writerLeaseRequired) {
            try file.save(IdentityAliasMapV1(aliases: []), holding: lease)
        }
    }

    @Test("A missing document is empty and a saved alias map round-trips")
    func atomicJSONRoundTrips() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let acquired = try UsageWriterLease.acquire(paths: fixture.paths)
        let lease = try #require(acquired)
        let file = AtomicJSONFile<IdentityAliasMapV1>(url: fixture.paths.identityAliases)
        let value = IdentityAliasMapV1(aliases: [
            IdentityAliasMapV1.Alias(
                providerID: "codex",
                retiredAccountID: "slot:retired",
                canonicalAccountID: "canonical:current",
                recordedAt: 1_900_000_000
            )
        ])

        #expect(try file.load() == nil)
        try file.save(value, holding: lease)
        #expect(try file.load() == value)
    }

    @Test("Corrupt JSON fails closed without changing its bytes")
    func corruptJSONIsNotRepaired() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bytes = Data("not-json".utf8)
        try FileManager.default.createDirectory(
            at: fixture.paths.rootDirectory,
            withIntermediateDirectories: true
        )
        try bytes.write(to: fixture.paths.identityAliases)
        let file = AtomicJSONFile<IdentityAliasMapV1>(url: fixture.paths.identityAliases)

        #expect(throws: UsagePersistenceError.self) { try file.load() }
        #expect(try Data(contentsOf: fixture.paths.identityAliases) == bytes)
    }

    private final class Fixture {
        let paths: UsagePersistencePaths

        init() throws {
            let root = FileManager.default.temporaryDirectory
                .appending(
                    path: "UsagePersistenceTests-" + UUID().uuidString,
                    directoryHint: .isDirectory
                )
            paths = UsagePersistencePaths(rootDirectory: root)
        }

        func remove() {
            try? FileManager.default.removeItem(at: paths.rootDirectory)
        }
    }
}
