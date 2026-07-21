import Foundation
import Testing

@testable import UsageKit

@Suite("Identity reconciliation")
struct IdentityReconciliationTests {
    private let now = Fixtures.capturedAt

    @Test("An active slot and a profile slot resolving to one canonical ID project one account")
    func activeAndProfileDuplicatesMerge() {
        var reconciler = IdentityReconciler()
        let canonical = Fixtures.canonicalKey("shared")
        let activeRoot = ProfileRootID()
        let profileRoot = ProfileRootID()
        #expect(
            reconciler.observe(fallback: Fixtures.slotKey("active"), canonical: canonical, at: now)
                == .recorded
        )
        #expect(
            reconciler.observe(fallback: Fixtures.slotKey("profile"), canonical: canonical, at: now)
                == .recorded
        )

        let projections = reconciler.project([
            Fixtures.account(
                key: Fixtures.slotKey("active"),
                slot: Fixtures.slot("active"),
                profileRootID: activeRoot,
                displayName: "shared@example.com",
                availability: .active
            ),
            Fixtures.account(
                key: Fixtures.slotKey("profile"),
                slot: Fixtures.slot("profile"),
                profileRootID: profileRoot,
                displayName: "shared@example.com"
            ),
        ])

        #expect(projections.count == 1)
        #expect(projections[0].key == canonical)
        #expect(projections[0].slots.map(\.opaqueID) == ["active", "profile"])
        #expect(projections[0].profileRootIDs == [activeRoot, profileRoot])
        #expect(projections[0].availability == .active)
    }

    @Test("Two accounts with the same display email stay separate")
    func equalDisplayEmailsDoNotMerge() {
        let reconciler = IdentityReconciler()
        let projections = reconciler.project([
            Fixtures.account(
                key: Fixtures.canonicalKey("one"),
                slot: Fixtures.slot("one"),
                displayName: "same@example.com"
            ),
            Fixtures.account(
                key: Fixtures.canonicalKey("two"),
                slot: Fixtures.slot("two"),
                displayName: "same@example.com"
            ),
        ])
        #expect(projections.count == 2)
        #expect(projections[0].key != projections[1].key)
    }

    @Test("A missing canonical ID stays slot-scoped rather than merging on a guess")
    func missingCanonicalIDStaysSlotScoped() {
        let reconciler = IdentityReconciler()
        let first = Fixtures.slotKey("slot-a")
        let second = Fixtures.slotKey("slot-b")
        #expect(reconciler.resolve(first) == first)
        #expect(reconciler.resolve(second) == second)

        let projections = reconciler.project([
            Fixtures.account(key: first, slot: Fixtures.slot("slot-a")),
            Fixtures.account(key: second, slot: Fixtures.slot("slot-b")),
        ])
        #expect(projections.count == 2)
    }

    @Test("Late canonical discovery retires the fallback and keeps one live row")
    func lateCanonicalDiscoveryPromotesInPlace() throws {
        var table = AccountStateTable()
        let fallback = Fixtures.slotKey("slot-a")
        let canonical = Fixtures.canonicalKey("acct-1")
        table.replaceDiscovered(
            [Fixtures.account(key: fallback, slot: Fixtures.slot("slot-a"), availability: .active)],
            forProvider: Fixtures.provider,
            at: now
        )
        let earlyReport = try report(for: fallback, at: now)
        table.apply(earlyReport, at: now)
        #expect(table.accounts.count == 1)

        #expect(table.promote(fallback: fallback, canonical: canonical, at: now) == .recorded)
        #expect(table.accounts.count == 1)
        #expect(table[fallback]?.account.key == canonical)
        #expect(table[canonical]?.report == earlyReport)
        #expect(table.reconciler.resolve(fallback) == canonical)
    }

    @Test("Promotion keeps every configured root represented on the surviving account")
    func promotionMergesConfiguredRoots() {
        var table = AccountStateTable()
        let canonical = Fixtures.canonicalKey("acct-1")
        let fallback = Fixtures.slotKey("profile")
        let canonicalRoot = ProfileRootID()
        let profileRoot = ProfileRootID()
        table.replaceDiscovered(
            [
                Fixtures.account(
                    key: canonical,
                    slot: Fixtures.slot("canonical"),
                    profileRootID: canonicalRoot
                ),
                Fixtures.account(
                    key: fallback,
                    slot: Fixtures.slot("profile"),
                    profileRootID: profileRoot
                ),
            ],
            forProvider: Fixtures.provider,
            at: now
        )

        #expect(table.promote(fallback: fallback, canonical: canonical, at: now) == .recorded)

        #expect(table.accounts.count == 1)
        #expect(table[canonical]?.account.profileRootIDs == [canonicalRoot, profileRoot])
    }

    @Test("Discovery itself records the promotion, so the cached report survives the identity flip")
    func discoveryPromotesASlotThatGainsACanonicalIdentity() throws {
        var table = AccountStateTable()
        let slot = Fixtures.slot("codex-auth")
        let fallback = Fixtures.slotKey("codex-auth")
        let canonical = Fixtures.canonicalKey("acct-1")
        table.replaceDiscovered(
            [Fixtures.account(key: fallback, slot: slot, availability: .active)],
            forProvider: Fixtures.provider,
            at: now
        )
        let cached = try report(for: fallback, at: now)
        table.apply(cached, at: now)

        table.replaceDiscovered(
            [Fixtures.account(key: canonical, slot: slot, availability: .active)],
            forProvider: Fixtures.provider,
            at: now
        )

        #expect(table.accounts.count == 1)
        #expect(table[canonical]?.report == cached, "the promotion carried the report across")
        #expect(table.reconciler.resolve(fallback) == canonical)

        // The credential file is caught mid-write, so the next discovery has no canonical ID
        // again. The alias has to fold it back onto the same row rather than start a new one.
        table.replaceDiscovered(
            [Fixtures.account(key: fallback, slot: slot, availability: .active)],
            forProvider: Fixtures.provider,
            at: now
        )
        #expect(table.accounts.count == 1)
        #expect(table[canonical]?.report == cached)
    }

    @Test("A retired row's stale error does not follow a newer report onto the canonical row")
    func promotionDropsAnErrorTheSurvivingReportOutlived() throws {
        var table = AccountStateTable()
        let fallback = Fixtures.slotKey("slot-a")
        let canonical = Fixtures.canonicalKey("acct-1")
        table.replaceDiscovered(
            [
                Fixtures.account(key: fallback, slot: Fixtures.slot("slot-a")),
                Fixtures.account(key: canonical, slot: Fixtures.slot("slot-b")),
            ],
            forProvider: Fixtures.provider,
            at: now
        )
        table.apply(try report(for: fallback, at: now), at: now)
        let expiry = UsageError(
            category: .authenticationExpired,
            reason: .credentialUnavailable(kind: .keychain)
        )
        table.apply(expiry, for: fallback, at: now.addingTimeInterval(60))
        let fresh = try report(for: canonical, at: now.addingTimeInterval(120))
        table.apply(fresh, at: now.addingTimeInterval(120))

        #expect(
            table.promote(fallback: fallback, canonical: canonical, at: now.addingTimeInterval(180))
                == .recorded
        )

        let state = try #require(table[canonical])
        #expect(state.report == fresh)
        #expect(state.lastError == nil, "the retired row's error was already superseded")
    }

    @Test("A reused slot resolving to a new canonical ID becomes a new account")
    func credentialReplacementDoesNotRewriteHistory() {
        var reconciler = IdentityReconciler()
        let slot = Fixtures.slotKey("reused")
        let first = Fixtures.canonicalKey("acct-1")
        let second = Fixtures.canonicalKey("acct-2")

        #expect(reconciler.observe(fallback: slot, canonical: first, at: now) == .recorded)
        #expect(
            reconciler.observe(fallback: slot, canonical: second, at: now)
                == .conflict(existing: first.accountID)
        )
        #expect(reconciler.resolve(slot) == first)
        #expect(reconciler.resolve(second) == second)
    }

    @Test("Re-observing the same promotion is a no-op, so a threshold cannot re-fire")
    func repeatedObservationIsUnchanged() {
        var reconciler = IdentityReconciler()
        let slot = Fixtures.slotKey("slot-a")
        let canonical = Fixtures.canonicalKey("acct-1")
        #expect(reconciler.observe(fallback: slot, canonical: canonical, at: now) == .recorded)
        #expect(reconciler.observe(fallback: slot, canonical: canonical, at: now) == .unchanged)
        #expect(reconciler.aliasMap.aliases.count == 1)
    }

    @Test("Only a fallback-to-canonical pair is a promotion")
    func nonPromotionPairsAreRejected() {
        var reconciler = IdentityReconciler()
        let canonicalA = Fixtures.canonicalKey("acct-1")
        let canonicalB = Fixtures.canonicalKey("acct-2")
        let slot = Fixtures.slotKey("slot-a")
        #expect(
            reconciler.observe(fallback: canonicalA, canonical: canonicalB, at: now)
                == .notApplicable)
        #expect(
            reconciler.observe(fallback: slot, canonical: Fixtures.slotKey("slot-b"), at: now)
                == .notApplicable)
        let otherProvider = AccountKey(
            providerID: ProviderID("other"),
            accountID: canonicalA.accountID
        )
        #expect(
            reconciler.observe(fallback: slot, canonical: otherProvider, at: now) == .notApplicable)
        #expect(reconciler.aliasMap.aliases.isEmpty)
    }

    @Test("A slot that disappears mid-refresh cannot resurrect its row")
    func slotDisappearingMidRefreshDropsItsResult() throws {
        var table = AccountStateTable()
        let staying = Fixtures.canonicalKey("staying")
        let leaving = Fixtures.canonicalKey("leaving")
        table.replaceDiscovered(
            [
                Fixtures.account(key: staying, slot: Fixtures.slot("staying")),
                Fixtures.account(key: leaving, slot: Fixtures.slot("leaving")),
            ],
            forProvider: Fixtures.provider,
            at: now
        )
        table.beginRefresh(leaving, at: now)

        table.replaceDiscovered(
            [Fixtures.account(key: staying, slot: Fixtures.slot("staying"))],
            forProvider: Fixtures.provider,
            at: now
        )
        #expect(table.accounts.count == 1)

        table.apply(try report(for: leaving, at: now), at: now)
        #expect(table.accounts.count == 1)
        #expect(table[leaving] == nil)
    }

    @Test("An alias map round-trips and rejects a duplicated retired identifier")
    func aliasMapRoundTrips() throws {
        var reconciler = IdentityReconciler()
        reconciler.observe(
            fallback: Fixtures.slotKey("slot-a"),
            canonical: Fixtures.canonicalKey("acct-1"),
            at: now
        )
        let encoded = try UsageJSON.encoder().encode(reconciler.aliasMap)
        let decoded = try UsageJSON.decoder().decode(IdentityAliasMapV1.self, from: encoded)
        let rebuilt = try IdentityReconciler(decoded)
        #expect(rebuilt == reconciler)

        let duplicated = IdentityAliasMapV1(
            aliases: decoded.aliases
                + decoded.aliases.map {
                    IdentityAliasMapV1.Alias(
                        providerID: $0.providerID,
                        retiredAccountID: $0.retiredAccountID,
                        canonicalAccountID: Fixtures.canonicalKey("acct-2").accountID.rawValue,
                        recordedAt: $0.recordedAt
                    )
                }
        )
        #expect(throws: UsageError.self) { try IdentityReconciler(duplicated) }
    }

    @Test("The alias map carries no display metadata or credential slot")
    func aliasMapIsTokenFree() throws {
        var reconciler = IdentityReconciler()
        reconciler.observe(
            fallback: Fixtures.slotKey("keychain-slot-1a2b"),
            canonical: Fixtures.canonicalKey("person@example.com"),
            at: now
        )
        let encoded = try Fixtures.encodedString(reconciler.aliasMap)
        #expect(!encoded.contains("keychain"))
        #expect(!encoded.contains("person"))
        #expect(!encoded.contains("example.com"))
    }

    private func report(for key: AccountKey, at date: Date) throws -> UsageReport {
        try UsageReport(
            accountKey: key,
            plan: "pro",
            windows: [
                UsageWindow(
                    id: WindowID(scope: .plan, slot: .primary, period: .weekly),
                    kind: .weekly,
                    label: "Weekly",
                    usedFraction: 0.5
                )
            ],
            capturedAt: date
        )
    }
}
