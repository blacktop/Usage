import SwiftUI
import UsageKit

struct ProviderAccountIssues: View {
    let accounts: [ProviderUsagePresentation.Account]
    let onRetry: (AccountKey, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(accounts) { account in
                let issue = ProviderAccountIssuePresentation(account: account)
                if let state = account.state, let error = issue.error {
                    ProviderErrorRow(
                        account: account,
                        error: error,
                        retryAt: issue.retryAt,
                        retry: { onRetry(state.account.key, error.requiresCredentialApproval) }
                    )
                }
                if let notice = issue.notice {
                    ProviderNoticeRow(account: account, message: notice)
                }
            }
        }
    }
}

struct ProviderAccountIssuePresentation {
    let error: UsageError?
    let notice: String?
    /// When the provider's `Retry-After` lapses, measured from the attempt that carried it.
    ///
    /// Rendered so a rate-limited card explains why nothing — the scheduler, the Retry button,
    /// a forced re-approval — will touch the endpoint before this instant. Without it, honoring
    /// the cooldown reads as the app silently ignoring the user.
    let retryAt: Date?

    init(account: ProviderUsagePresentation.Account) {
        let lastError = account.state?.lastError
        // A 429 is evidence about the provider endpoint, not proof that the account exhausted its
        // usage allowance. Keep it visible as an error, but do not offer a manual retry that could
        // hammer the endpoint ahead of the scheduler's backoff.
        let throttled = lastError?.category == .rateLimited
        error = lastError
        if let retry = lastError?.retry, let attemptAt = account.state?.lastAttemptAt {
            retryAt = attemptAt.addingTimeInterval(Double(retry.delay.components.seconds))
        } else {
            retryAt = nil
        }
        if throttled {
            notice = nil
        } else if account.state?.report?.isPartial == true {
            notice = "Some limits could not be read"
        } else if let state = account.state, state.report == nil, state.lastError == nil {
            notice = "No usage recorded yet"
        } else if let status = account.configuredProfile {
            notice =
                status.hasCredentialDocument
                ? "No usable account found"
                : "No readable credential found"
        } else {
            notice = nil
        }
    }
}

private struct ProviderErrorRow: View {
    let account: ProviderUsagePresentation.Account
    let error: UsageError
    let retryAt: Date?
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(AccountTint.color(at: account.colorIndex))
                .frame(width: 6, height: 6)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(account.label): \(error.message)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if error.category == .rateLimited, let retryAt {
                    let time = retryAt.formatted(date: .omitted, time: .shortened)
                    Text("Retries automatically at \(time).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let action = error.reauthentication {
                    Text(action.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command = action.command {
                        Text(command)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 6)
            if error.category != .rateLimited {
                Button(error.requiresCredentialApproval ? "Approve" : "Retry", action: retry)
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
    }
}

private struct ProviderNoticeRow: View {
    let account: ProviderUsagePresentation.Account
    let message: String

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(AccountTint.color(at: account.colorIndex))
                .frame(width: 6, height: 6)
            Text("\(account.label): \(message)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
