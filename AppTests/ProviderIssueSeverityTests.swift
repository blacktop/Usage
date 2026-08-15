import Foundation
import Testing
import UsageKit

@testable import Usage

@Suite("Issue presentation and meter severity")
@MainActor
struct ProviderIssueSeverityTests {
    private func account(lastError: UsageError?) -> ProviderUsagePresentation.Account {
        let id = ProviderID("claude")
        let key = AccountKey(providerID: id, accountID: .canonical(provider: id, canonicalID: "a"))
        return ProviderUsagePresentation.Account(
            id: .discovered(key),
            label: "Claude",
            colorIndex: 0,
            state: AccountState(
                account: AccountProjection(
                    key: key,
                    slots: [],
                    profileRootIDs: [],
                    displayName: "Claude",
                    availability: .active
                ),
                lastError: lastError
            ),
            configuredProfile: nil
        )
    }

    @Test("an endpoint 429 stays visible as an error rather than claiming quota exhaustion")
    func rateLimitedIsAnError() {
        let throttled = UsageError.from(HTTPResponse(status: 429))
        let issue = ProviderAccountIssuePresentation(
            account: account(lastError: throttled)
        )
        #expect(issue.error == throttled)
        #expect(issue.notice == nil)
    }

    @Test("failures that need the user keep the error row")
    func authenticationFailureKeepsTheErrorRow() {
        let expired = UsageError.from(HTTPResponse(status: 401))
        let issue = ProviderAccountIssuePresentation(account: account(lastError: expired))
        #expect(issue.error == expired)
    }

    @Test(
        "the severity override turns red only below ten percent remaining",
        arguments: [
            (0.0, true), (0.05, true), (0.099, true), (0.1, false), (0.5, false), (1.0, false),
        ]
    )
    func severityThreshold(remaining: Double, isCritical: Bool) {
        #expect((UsageSeverity.color(forRemaining: remaining) != nil) == isCritical)
    }
}
