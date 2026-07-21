import SwiftUI
import UsageKit

/// One discovered account: its identity, its last good report, and — separately — how its refresh
/// is going.
///
/// The report and the refresh state are rendered independently on purpose. A refresh in flight or
/// a failed one changes only the indicator and the error affordance; the numbers on screen stay
/// the last ones a provider actually returned.
struct AccountCard: View {
    /// What the header shows about the refresh itself, never about the data.
    enum RefreshIndicator: Equatable {
        case loading
        case failed
        case waiting

        static func forState(_ state: AccountState) -> RefreshIndicator? {
            if state.refreshPhase == .loading { return .loading }
            if state.lastError != nil { return .failed }
            return state.refreshPhase == .scheduled ? .waiting : nil
        }
    }

    let state: AccountState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let report = state.report {
                ForEach(report.windows) { window in
                    UsageWindowRow(window: window)
                }
                if let credits = report.credits {
                    CreditsRow(credits: credits)
                }
                if report.isPartial {
                    Label(
                        "Some limits could not be read.",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let freshness = Self.freshnessText(for: state) {
                    Text(freshness)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if state.lastError == nil {
                Text("No usage recorded yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = state.lastError {
                failure(error)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(state.account.displayName ?? "Unknown account")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if state.account.availability == .active {
                Text("active")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.tint.opacity(0.2), in: .capsule)
            }
            Spacer()
            indicator
            if let plan = state.report?.plan {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch RefreshIndicator.forState(state) {
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Refreshing")
        case .failed:
            Image(systemName: "arrow.trianglehead.clockwise")
                .foregroundStyle(.orange)
                .accessibilityLabel("Last refresh failed")
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Refresh scheduled")
        case nil:
            EmptyView()
        }
    }

    private func failure(_ error: UsageError) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            if let action = error.reauthentication {
                Text(action.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let command = action.command {
                    Text(command)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
            Button("Try again", action: onRetry)
                .buttonStyle(.glass)
                .font(.caption)
        }
    }

    /// How old the visible numbers are, and whether they are being shown despite a failure.
    static func freshnessText(for state: AccountState) -> String? {
        guard let report = state.report else { return nil }
        let age = report.capturedAt.formatted(.relative(presentation: .numeric))
        return state.lastError == nil ? "updated \(age)" : "showing usage from \(age)"
    }
}

struct CreditsRow: View {
    let credits: CreditBalance

    var body: some View {
        HStack {
            Text("Credits")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(CreditsRow.text(for: credits))
                .font(.caption.monospacedDigit())
        }
    }

    /// A monetary balance is rendered in its currency, exactly as a money window is; a balance in a
    /// provider-defined unit is rendered as a bare number.
    static func text(for credits: CreditBalance) -> String {
        let remaining = amount(credits.remaining, in: credits.currency)
        guard let granted = credits.granted else { return remaining }
        return "\(remaining) of \(amount(granted, in: credits.currency))"
    }

    private static func amount(_ value: Decimal, in currency: String?) -> String {
        guard let currency else {
            return value.formatted(.number.precision(.fractionLength(0...2)))
        }
        return value.formatted(.currency(code: currency))
    }
}
