import Foundation

/// `usage list` output: one row per usage window, then credits, then failures.
///
/// The account column shows the provider's own display label when it offered one and a short
/// identity digest otherwise. A credential path is never printed, in the table or in a failure:
/// the same rule that keeps it out of `usage json` and the logs applies here.
public enum UsageTable {
    private static let absent = "-"
    private static let digestPrefixLength = 12

    public static func render(_ collection: UsageCollection, now: Date) -> String {
        var sections: [[String]] = []
        let windows = windowRows(collection, now: now)
        if windows.isEmpty, collection.accounts.isEmpty {
            sections.append(["No accounts reported usage."])
        } else {
            sections.append(
                TextTable.render(
                    header: ["PROVIDER", "ACCOUNT", "PLAN", "WINDOW", "USED", "RESETS"],
                    rows: windows,
                    alignment: [.leading, .leading, .leading, .leading, .trailing, .leading]
                )
            )
        }
        sections.append(creditSection(collection))
        sections.append(partialSection(collection))
        sections.append(failureSection(collection))
        return sections.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }
            .joined(separator: "\n\n")
    }

    private static func windowRows(_ collection: UsageCollection, now: Date) -> [[String]] {
        collection.accounts.flatMap { collected in
            collected.report.windows.map { window in
                [
                    collected.report.accountKey.providerID.rawValue,
                    label(for: collected),
                    collected.report.plan ?? absent,
                    window.label,
                    percentage(window.usedFraction),
                    window.resetsAt.map { RelativeTime.short(from: now, to: $0) } ?? absent,
                ]
            }
        }
    }

    private static func creditSection(_ collection: UsageCollection) -> [String] {
        let rows = collection.accounts.compactMap { collected -> [String]? in
            guard let credits = collected.report.credits else { return nil }
            return [
                collected.report.accountKey.providerID.rawValue,
                label(for: collected),
                [credits.remaining.description, credits.currency].compactMap { $0 }
                    .joined(separator: " "),
            ]
        }
        guard !rows.isEmpty else { return [] }
        return TextTable.render(header: ["PROVIDER", "ACCOUNT", "CREDITS"], rows: rows)
    }

    /// Accounts whose response was only partly readable.
    ///
    /// Rendered separately from failures because the rows above are real: the warning is that they
    /// are not all of them, which is the one thing a bare table cannot say.
    private static func partialSection(_ collection: UsageCollection) -> [String] {
        let rows = collection.accounts.filter(\.report.isPartial).map { collected in
            "  \(collected.report.accountKey.providerID.rawValue)  \(label(for: collected))"
        }
        guard !rows.isEmpty else { return [] }
        return ["PARTIAL (some limits could not be read)"] + rows
    }

    /// Failures are rendered as lines rather than as a table because the second line is an
    /// instruction to the reader, not another value in the same column.
    private static func failureSection(_ collection: UsageCollection) -> [String] {
        guard !collection.failures.isEmpty else { return [] }
        var lines = ["FAILURES"]
        for failure in collection.failures {
            lines.append(
                "  \(failure.providerID.rawValue)  \(failure.error.category.rawValue): "
                    + failure.error.message + retrySuffix(failure.error)
            )
            if let action = failure.error.reauthentication {
                lines.append("    " + instruction(action))
            }
        }
        return lines
    }

    private static func retrySuffix(_ error: UsageError) -> String {
        guard let retry = error.retry else { return "" }
        return " (retry in \(retry.delay.components.seconds)s, \(retry.scope.rawValue) scope)"
    }

    private static func instruction(_ action: ReauthAction) -> String {
        guard let command = action.command else { return action.summary }
        return "\(action.summary) Run: \(command)"
    }

    private static func label(for collected: CollectedAccount) -> String {
        collected.account.displayName
            ?? String(collected.report.accountKey.accountID.digest.prefix(digestPrefixLength))
    }

    /// Rounded to whole percent. Values above 100 are printed as they are: an over-quota account is
    /// exactly the case a clamp would hide.
    private static func percentage(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// Short relative times such as `4h 51m`, for a reset column that has to stay narrow.
enum RelativeTime {
    static func short(from now: Date, to date: Date) -> String {
        let seconds = Int(date.timeIntervalSince(now).rounded())
        guard seconds > 0 else { return "due" }
        if seconds < 60 { return "<1m" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 {
            return compound(
                major: seconds / 3600, unit: "h", rest: seconds % 3600 / 60, restUnit: "m")
        }
        return compound(
            major: seconds / 86_400, unit: "d", rest: seconds % 86_400 / 3600, restUnit: "h")
    }

    private static func compound(major: Int, unit: String, rest: Int, restUnit: String) -> String {
        rest == 0 ? "\(major)\(unit)" : "\(major)\(unit) \(rest)\(restUnit)"
    }
}
