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

    init(account: ProviderUsagePresentation.Account) {
        error = account.state?.lastError
        if account.state?.report?.isPartial == true {
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
            Button(error.requiresCredentialApproval ? "Approve" : "Retry", action: retry)
                .buttonStyle(.link)
                .font(.caption2)
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
