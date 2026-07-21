import Foundation

@testable import UsageKit

enum Fixtures {
    static let provider = ProviderID("preview")
    static let capturedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let recordedAt = Date(timeIntervalSince1970: 1_700_000_060)

    static func canonicalKey(_ canonicalID: String) -> AccountKey {
        AccountKey(
            providerID: provider,
            accountID: .canonical(provider: provider, canonicalID: canonicalID)
        )
    }

    static func slot(_ opaqueID: String) -> CredentialSlotID {
        CredentialSlotID(source: "keychain", opaqueID: opaqueID)
    }

    static func slotKey(_ opaqueID: String) -> AccountKey {
        AccountKey(
            providerID: provider,
            accountID: .credentialSlot(provider: provider, slot: slot(opaqueID))
        )
    }

    static func account(
        key: AccountKey,
        slot slotID: CredentialSlotID,
        displayName: String? = nil,
        availability: ProviderAccount.Availability = .inactive
    ) -> ProviderAccount {
        ProviderAccount(
            key: key,
            slot: slotID,
            locator: CredentialLocator(kind: .keychain, identifier: slotID.opaqueID),
            displayName: displayName,
            availability: availability
        )
    }

    /// The report the golden schema tests lock. Exercises both detail kinds, an over-quota
    /// fraction, an absent reset date, and a credit balance.
    static func goldenReport() throws -> UsageReport {
        try UsageReport(
            accountKey: canonicalKey("golden"),
            plan: "pro",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .session),
                    kind: .session,
                    label: "Session",
                    usedFraction: 0.25,
                    resetsAt: Date(timeIntervalSince1970: 1_700_003_600),
                    duration: .seconds(18_000),
                    detail: .count(used: 25, limit: 100)
                ),
                UsageWindow(
                    id: WindowID(
                        scope: .additional(feature: "premium-requests"),
                        slot: .secondary,
                        period: .weekly
                    ),
                    kind: .named("premium-requests"),
                    label: "Premium requests",
                    usedFraction: 1.5,
                    detail: .money(spent: Decimal(15), budget: Decimal(10), currency: "USD")
                ),
            ],
            credits: CreditBalance(
                remaining: Decimal(35),
                granted: Decimal(50),
                currency: "USD",
                expiresAt: Date(timeIntervalSince1970: 1_702_592_000)
            ),
            capturedAt: capturedAt
        )
    }

    static func context(clock: ManualClock = ManualClock()) -> ProviderContext {
        ProviderContext(
            http: InMemoryHTTPTransport(),
            credentials: InMemoryCredentialSource(),
            fileSystem: InMemoryFileSystem(),
            clock: clock,
            interaction: BackgroundInteractionPolicy()
        )
    }

    static func encodedString(_ value: some Encodable) throws -> String {
        let data = try UsageJSON.encoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
