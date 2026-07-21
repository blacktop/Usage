import Foundation

/// A provider that answers from synthetic data, so the app, the CLI, and the store can be
/// exercised end to end with no network, no credential, and no Keychain.
///
/// The three accounts deliberately cover the awkward shapes: an over-quota window above 100%, a
/// window with no provider-supplied reset date, a count-based detail, a money-based detail, and a
/// credit balance.
public struct PreviewProvider: Provider {
    public static let id = ProviderID("preview")

    public let displayName = "Preview"
    public let dashboardURL = URL(filePath: "/dev/null")

    public init() {}

    public func discoverAccounts(using context: ProviderContext) async throws -> [ProviderAccount] {
        Self.blueprints.map(\.account)
    }

    public func fetchUsage(
        for account: ProviderAccount,
        using context: ProviderContext
    ) async throws -> UsageReport {
        guard let blueprint = Self.blueprints.first(where: { $0.account.key == account.key }) else {
            throw UsageError.providerUnavailable()
        }
        return try blueprint.report(at: context.clock.now)
    }
}

extension PreviewProvider {
    private struct Blueprint: Sendable {
        let account: ProviderAccount
        let plan: String
        let build: @Sendable (Date) throws -> ([UsageWindow], CreditBalance?)

        func report(at date: Date) throws -> UsageReport {
            let (windows, credits) = try build(date)
            return try UsageReport(
                accountKey: account.key,
                plan: plan,
                windows: windows,
                credits: credits,
                capturedAt: date
            )
        }
    }

    private static func account(
        canonicalID: String,
        displayName: String,
        availability: ProviderAccount.Availability
    ) -> ProviderAccount {
        let slot = CredentialSlotID(source: "preview", opaqueID: canonicalID)
        return ProviderAccount(
            key: AccountKey(
                providerID: id,
                accountID: .canonical(provider: id, canonicalID: canonicalID)
            ),
            slot: slot,
            locator: CredentialLocator(kind: .file, identifier: "/dev/null"),
            displayName: displayName,
            availability: availability
        )
    }

    private static let blueprints: [Blueprint] = [
        Blueprint(
            account: account(
                canonicalID: "preview-alpha",
                displayName: "alpha@example.com",
                availability: .active
            ),
            plan: "pro",
            build: { date in (try alphaWindows(at: date), nil) }
        ),
        Blueprint(
            account: account(
                canonicalID: "preview-beta",
                displayName: "beta@example.com",
                availability: .inactive
            ),
            plan: "team",
            build: { date in (try betaWindows(at: date), nil) }
        ),
        Blueprint(
            account: account(
                canonicalID: "preview-gamma",
                displayName: "gamma@example.com",
                availability: .inactive
            ),
            plan: "pay-as-you-go",
            build: { date in
                (
                    try gammaWindows(at: date),
                    try CreditBalance(
                        remaining: Decimal(35),
                        granted: Decimal(50),
                        currency: "USD",
                        expiresAt: date.addingTimeInterval(30 * 86_400)
                    )
                )
            }
        ),
    ]

    private static func alphaWindows(at date: Date) throws -> [UsageWindow] {
        [
            try UsageWindow(
                id: WindowID(scope: .plan, slot: .primary, period: .session),
                kind: .session,
                label: "Session",
                usedFraction: 0.42,
                resetsAt: date.addingTimeInterval(2 * 3_600),
                duration: .seconds(5 * 3_600),
                detail: .count(used: 126, limit: 300)
            ),
            try UsageWindow(
                id: WindowID(scope: .plan, slot: .secondary, period: .weekly),
                kind: .weekly,
                label: "Weekly",
                usedFraction: 1.18,
                resetsAt: date.addingTimeInterval(3 * 86_400),
                duration: .seconds(7 * 86_400)
            ),
        ]
    }

    private static func betaWindows(at date: Date) throws -> [UsageWindow] {
        [
            try UsageWindow(
                id: WindowID(scope: .plan, slot: .primary, period: .monthly),
                kind: .monthly,
                label: "Monthly",
                usedFraction: 0.67
            ),
            try UsageWindow(
                id: WindowID(
                    scope: .additional(feature: "premium-requests"),
                    slot: .primary,
                    period: .monthly
                ),
                kind: .named("premium-requests"),
                label: "Premium requests",
                usedFraction: 0.24,
                resetsAt: date.addingTimeInterval(11 * 86_400),
                detail: .count(used: 72, limit: 300)
            ),
        ]
    }

    private static func gammaWindows(at date: Date) throws -> [UsageWindow] {
        [
            try UsageWindow(
                id: WindowID(
                    scope: .additional(feature: "budget"),
                    slot: .primary,
                    period: .monthly
                ),
                kind: .named("budget"),
                label: "Monthly budget",
                usedFraction: 0.3,
                resetsAt: date.addingTimeInterval(9 * 86_400),
                detail: .money(spent: Decimal(15), budget: Decimal(50), currency: "USD")
            )
        ]
    }
}
