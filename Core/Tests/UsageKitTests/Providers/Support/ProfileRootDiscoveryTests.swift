import Foundation
import Testing

@testable import UsageKit

/// Configured roots are the only thing account discovery reads.
///
/// The suites beside this one exercise one root each, which is the shape that keeps them readable.
/// This is where the property that actually changed is asserted: several enabled roots are several
/// independently labelled accounts, a disabled root is not opened at all, and neither the home
/// directory nor the Keychain contributes anything.
@Suite("Configured-root discovery")
struct ProfileRootDiscoveryTests {
    private static let personal = ProviderFixtures.root("profiles/personal")
    private static let work = ProviderFixtures.root("profiles/work")
    private static let archived = ProviderFixtures.root("profiles/archived")

    // MARK: - Codex

    @Test("every enabled Codex root becomes its own labelled account, in configuration order")
    func codexDiscoversOneAccountPerRoot() async throws {
        let auth = try ProviderFixtures.data("Codex", "codex-auth")
        let files = SealedFileSystem(
            files: [
                CodexAuthFile.url(root: Self.personal): auth,
                CodexAuthFile.url(root: Self.work): auth,
            ]
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(CodexProvider.id, label: "Work", at: Self.work),
                SealedProfileRoots.root(CodexProvider.id, label: "Personal", at: Self.personal)
            )
        )

        let accounts = try await CodexProvider().discoverAccounts(using: context)

        #expect(accounts.map(\.displayName) == ["Work", "Personal"])
        #expect(
            accounts.map(\.slot.opaqueID) == [
                "/Users/fixture/profiles/work/auth.json",
                "/Users/fixture/profiles/personal/auth.json",
            ],
            "slot identity follows the root's path, so it survives a relabel"
        )
        #expect(files.readsOutsideHome.isEmpty)
    }

    /// Both fixture files name the same `account_id`, so canonical reconciliation folds the two
    /// roots onto one identity. That is deliberate: the same workspace reached twice is one
    /// account. Slot identity stays per-root regardless, which is what the following account keeps.
    @Test("Codex keeps canonical reconciliation across roots but path-stable slots")
    func codexReconcilesCanonicalIdentityAcrossRoots() async throws {
        let auth = try ProviderFixtures.data("Codex", "codex-auth")
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    CodexAuthFile.url(root: Self.personal): auth,
                    CodexAuthFile.url(root: Self.work): auth,
                ]
            ),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(CodexProvider.id, label: "Work", at: Self.work),
                SealedProfileRoots.root(CodexProvider.id, label: "Personal", at: Self.personal)
            )
        )

        let accounts = try await CodexProvider().discoverAccounts(using: context)

        #expect(accounts.count == 2)
        #expect(accounts.allSatisfy { $0.key.accountID.derivation == .canonical })
        #expect(Set(accounts.map(\.key)).count == 1)
        #expect(Set(accounts.map(\.slot)).count == 2)
    }

    @Test("a Codex root whose file is missing contributes no account and no read of its sibling")
    func codexSkipsRootWithoutFile() async throws {
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    CodexAuthFile.url(root: Self.work): try ProviderFixtures.data(
                        "Codex",
                        "codex-auth"
                    )
                ]
            ),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(CodexProvider.id, label: "Work", at: Self.work),
                SealedProfileRoots.root(CodexProvider.id, label: "Empty", at: Self.personal)
            )
        )

        let accounts = try await CodexProvider().discoverAccounts(using: context)

        #expect(accounts.map(\.displayName) == ["Work"])
    }

    // MARK: - Claude

    @Test("every enabled Claude root becomes its own labelled account")
    func claudeDiscoversOneAccountPerRoot() async throws {
        let credential = try ProviderFixtures.data("Claude", "claude-credential-happy")
        let files = SealedFileSystem(
            files: [
                ClaudeCredentialFile.url(root: Self.personal): credential,
                ClaudeCredentialFile.url(root: Self.work): credential,
            ]
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            clock: ManualClock(now: Date(timeIntervalSince1970: 1_784_000_000)),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(ClaudeProvider.id, label: "Personal", at: Self.personal),
                SealedProfileRoots.root(ClaudeProvider.id, label: "Work", at: Self.work)
            )
        )

        let accounts = try await ClaudeProvider().discoverAccounts(using: context)

        #expect(accounts.map(\.displayName) == ["Personal", "Work"])
        #expect(Set(accounts.map(\.key)).count == 2, "two roots are two accounts")
        #expect(accounts.allSatisfy { $0.availability == .active })
        #expect(files.readsOutsideHome.isEmpty)
    }

    // MARK: - Copilot

    @Test("Copilot precedence is scoped to a root, so the same host under two roots survives twice")
    func copilotAppliesPrecedencePerRoot() async throws {
        let apps = try ProviderFixtures.data("Copilot", "copilot-apps")
        let hosts = try ProviderFixtures.data("Copilot", "copilot-hosts")
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    CopilotCredentialFiles.url(root: Self.personal, fileName: "apps.json"): apps,
                    CopilotCredentialFiles.url(root: Self.work, fileName: "hosts.json"): hosts,
                ]
            ),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(CopilotProvider.id, label: "Personal", at: Self.personal),
                SealedProfileRoots.root(CopilotProvider.id, label: "Work", at: Self.work)
            )
        )

        let accounts = try await CopilotProvider().discoverAccounts(using: context)

        #expect(accounts.map(\.displayName) == ["Personal", "Personal", "Work", "Work"])
        #expect(
            accounts.map(CopilotProvider.host(of:)) == [
                "github.com", "octofixture.ghe.com", "github.com", "legacy.ghe.example",
            ],
            "the second root's github.com is not swallowed by the first root's"
        )
        #expect(Set(accounts.map(\.key)).count == 4)
    }

    /// The same `apps.json` under two roots: identical file name, identical entry keys. Only the
    /// path tells the two apart, so a slot identifier built from the entry key alone would collapse
    /// four accounts into two and the second root would vanish from the store.
    @Test("identical Copilot entries under two roots stay four distinct accounts")
    func copilotSlotsAreQualifiedByPath() async throws {
        let apps = try ProviderFixtures.data("Copilot", "copilot-apps")
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    CopilotCredentialFiles.url(root: Self.personal, fileName: "apps.json"): apps,
                    CopilotCredentialFiles.url(root: Self.work, fileName: "apps.json"): apps,
                ]
            ),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(CopilotProvider.id, label: "Personal", at: Self.personal),
                SealedProfileRoots.root(CopilotProvider.id, label: "Work", at: Self.work)
            )
        )

        let accounts = try await CopilotProvider().discoverAccounts(using: context)

        #expect(accounts.count == 4)
        #expect(Set(accounts.map(\.slot)).count == 4)
        #expect(Set(accounts.map(\.key)).count == 4)
        #expect(accounts.map(\.displayName) == ["Personal", "Personal", "Work", "Work"])
        #expect(
            accounts.map(CopilotProvider.host(of:)) == [
                "github.com", "octofixture.ghe.com", "github.com", "octofixture.ghe.com",
            ],
            "the host still comes back out of a path-qualified slot"
        )
    }

    // MARK: - Disabled roots

    @Test(
        "a disabled root yields no account and is never opened",
        arguments: ProviderRegistry.agents.providers.map(\.providerID)
    )
    func disabledRootIsNeverRead(providerID: ProviderID) async throws {
        let provider = try #require(ProviderRegistry.agents.provider(for: providerID))
        let files = SealedFileSystem(files: try Self.everyDocument(at: Self.archived))
        let credentials = SealedCredentialSource()
        let context = ProviderContext.sealed(
            fileSystem: files,
            credentials: credentials,
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(
                    providerID,
                    label: "Archived",
                    at: Self.archived,
                    isEnabled: false
                )
            )
        )

        let accounts = try await provider.discoverAccounts(using: context)

        #expect(accounts.isEmpty)
        #expect(files.recordedReads.isEmpty, "a disabled root is dropped before any file is named")
        #expect(credentials.resolvedLocators.isEmpty)
        #expect(credentials.enumeratedNamespaces.isEmpty)
        #expect(files.isUnmodified)
    }

    @Test("an enabled root beside a disabled one is still discovered")
    func enabledRootSurvivesADisabledSibling() async throws {
        let auth = try ProviderFixtures.data("Codex", "codex-auth")
        let context = ProviderContext.sealed(
            fileSystem: SealedFileSystem(
                files: [
                    CodexAuthFile.url(root: Self.work): auth,
                    CodexAuthFile.url(root: Self.archived): auth,
                ]
            ),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(
                    CodexProvider.id,
                    label: "Archived",
                    at: Self.archived,
                    isEnabled: false
                ),
                SealedProfileRoots.root(CodexProvider.id, label: "Work", at: Self.work)
            )
        )

        let accounts = try await CodexProvider().discoverAccounts(using: context)

        #expect(accounts.map(\.displayName) == ["Work"])
    }

    // MARK: - Nothing but the configured roots

    @Test(
        "a provider with no configured root discovers nothing, whatever the home directory holds",
        arguments: ProviderRegistry.agents.providers.map(\.providerID)
    )
    func noRootMeansNoAccount(providerID: ProviderID) async throws {
        let provider = try #require(ProviderRegistry.agents.provider(for: providerID))
        var seeded = try Self.everyDocument(at: ProviderFixtures.claudeRoot)
        for (url, data) in try Self.everyDocument(at: ProviderFixtures.codexRoot) {
            seeded[url] = data
        }
        for (url, data) in try Self.everyDocument(at: ProviderFixtures.copilotRoot) {
            seeded[url] = data
        }
        let files = SealedFileSystem(files: seeded)
        let context = ProviderContext.sealed(
            fileSystem: files,
            profileRoots: try SealedProfileRoots.store()
        )

        #expect(try await provider.discoverAccounts(using: context).isEmpty)
        #expect(files.recordedReads.isEmpty)
    }

    @Test(
        "a root outside the home directory is read exactly where it points",
        arguments: ProviderRegistry.agents.providers.map(\.providerID)
    )
    func rootsAreNotResolvedAgainstTheHomeDirectory(providerID: ProviderID) async throws {
        let provider = try #require(ProviderRegistry.agents.provider(for: providerID))
        let elsewhere = URL(filePath: "/Volumes/fixture/agents", directoryHint: .isDirectory)
        let files = SealedFileSystem(files: try Self.everyDocument(at: elsewhere))
        let context = ProviderContext.sealed(
            fileSystem: files,
            clock: ManualClock(now: Date(timeIntervalSince1970: 1_784_000_000)),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(providerID, label: "Elsewhere", at: elsewhere)
            )
        )

        let accounts = try await provider.discoverAccounts(using: context)

        #expect(!accounts.isEmpty)
        #expect(accounts.allSatisfy { $0.displayName == "Elsewhere" })
        #expect(
            accounts.allSatisfy {
                $0.locator.identifier.hasPrefix("/Volumes/fixture/agents/")
            },
            "nothing rewrites a configured root onto the injected home"
        )
    }

    /// Every root is seeded with every provider's documents, so a provider that opened a file it
    /// does not own would find one there. The assertion is on the exact set of paths touched, not
    /// on the accounts produced: reading a neighbour's credential and discarding it is a read too.
    @Test(
        "a provider opens only the documents it declares, and only below its own roots",
        arguments: [
            (CodexProvider.id, ["auth.json"]),
            (ClaudeProvider.id, [".credentials.json"]),
            (CopilotProvider.id, ["apps.json", "hosts.json", "oauth.json"]),
        ]
    )
    func readsOnlyItsOwnDocuments(providerID: ProviderID, documents: [String]) async throws {
        let provider = try #require(ProviderRegistry.agents.provider(for: providerID))
        var seeded = try Self.everyDocument(at: Self.personal)
        for (url, data) in try Self.everyDocument(at: Self.work) {
            seeded[url] = data
        }
        let files = SealedFileSystem(files: seeded)
        let context = ProviderContext.sealed(
            fileSystem: files,
            clock: ManualClock(now: Date(timeIntervalSince1970: 1_784_000_000)),
            profileRoots: try SealedProfileRoots.store(
                SealedProfileRoots.root(providerID, label: "Personal", at: Self.personal)
            )
        )

        _ = try await provider.discoverAccounts(using: context)

        let expected = documents.map {
            Self.personal.appending(path: $0, directoryHint: .notDirectory)
                .standardizedFileURL.path(percentEncoded: false)
        }
        let touched = files.recordedReads.map {
            $0.standardizedFileURL.path(percentEncoded: false)
        }
        #expect(Set(touched) == Set(expected))
        #expect(!touched.contains { $0.hasPrefix("/Users/fixture/profiles/work/") })
    }

    // MARK: - Unreadable storage

    @Test(
        "storage that cannot be read is a discovery failure, not a silent fall back to defaults",
        arguments: ProviderRegistry.agents.providers.map(\.providerID)
    )
    func unreadableStorageFailsDiscovery(providerID: ProviderID) async throws {
        let provider = try #require(ProviderRegistry.agents.provider(for: providerID))
        let files = SealedFileSystem(
            files: try Self.everyDocument(at: ProviderFixtures.claudeRoot)
                .merging(try Self.everyDocument(at: ProviderFixtures.codexRoot)) { first, _ in
                    first
                }
                .merging(try Self.everyDocument(at: ProviderFixtures.copilotRoot)) { first, _ in
                    first
                }
        )
        let context = ProviderContext.sealed(
            fileSystem: files,
            profileRoots: UnreadableProfileRootStore()
        )

        await #expect(throws: UsageError.providerUnavailable()) {
            _ = try await provider.discoverAccounts(using: context)
        }
        #expect(files.recordedReads.isEmpty, "the seeded defaults were not substituted")
    }

    @Test(
        "every storage failure surfaces, none is repaired",
        arguments: [
            ProfileRootStoreError.corruptPayload,
            .unsupportedSchemaVersion(99),
            .storageUnavailable,
        ]
    )
    func everyStorageFailureSurfaces(error: ProfileRootStoreError) async throws {
        let context = ProviderContext.sealed(profileRoots: UnreadableProfileRootStore(error))
        await #expect(throws: UsageError.providerUnavailable()) {
            _ = try await CodexProvider().discoverAccounts(using: context)
        }
    }

    // MARK: - Helpers

    /// Every document any provider knows how to read, seeded below one directory.
    ///
    /// Used to make the negative assertions strong: a provider that reached for the wrong root
    /// would find something there, so `isEmpty` means it did not reach rather than that it reached
    /// and found nothing.
    private static func everyDocument(at root: URL) throws -> [URL: Data] {
        var files: [URL: Data] = [
            CodexAuthFile.url(root: root): try ProviderFixtures.data("Codex", "codex-auth"),
            ClaudeCredentialFile.url(root: root): try ProviderFixtures.data(
                "Claude",
                "claude-credential-happy"
            ),
        ]
        for fileName in CopilotCredentialFiles.fileNames {
            files[CopilotCredentialFiles.url(root: root, fileName: fileName)] =
                try ProviderFixtures.data("Copilot", "copilot-apps")
        }
        return files
    }
}
