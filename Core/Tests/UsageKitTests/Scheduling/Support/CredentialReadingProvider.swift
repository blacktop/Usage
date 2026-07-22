import Foundation
import Synchronization

@testable import UsageKit

/// A provider whose fetch cannot succeed unless the context resolves its credential.
///
/// Used to distinguish a fetch performed inside a user-authorized read from an approval probe
/// followed by a second background read.
final class CredentialReadingProvider: Provider, Sendable {
    static let id = ProviderID("credential-reading")

    let displayName = "Credential reading"
    let dashboardURL = URL(filePath: "/dev/null")
    let account: ProviderAccount

    private let count = Mutex(0)

    var fetchCount: Int { count.withLock { $0 } }

    init() {
        let slot = CredentialSlotID(source: "credential-reading", opaqueID: "fixture")
        account = ProviderAccount(
            key: AccountKey(
                providerID: Self.id,
                accountID: .credentialSlot(provider: Self.id, slot: slot)
            ),
            slot: slot,
            locator: CredentialLocator(kind: .keychain, identifier: "fixture-reference"),
            displayName: "fixture",
            availability: .active
        )
    }

    func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        [account]
    }

    func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        count.withLock { $0 += 1 }
        return try await context.credentials.withCredential(at: account.locator) { _ in
            try UsageReport(
                accountKey: account.key,
                plan: "fixture",
                windows: [],
                capturedAt: context.clock.now
            )
        }
    }
}
