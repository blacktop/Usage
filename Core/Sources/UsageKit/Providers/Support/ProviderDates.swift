import Foundation

/// Date shapes the three agent endpoints actually emit.
///
/// None of them documents a format, and two of them emit more than one, so every parse here is
/// tolerant and returns `nil` rather than substituting a wrong instant.
enum ProviderDates {
    /// ISO-8601 with fractional seconds preferred, then without.
    ///
    /// Real payloads mix `2026-07-20T18:30:00.000Z` with `2026-07-24T09:00:00.282694+00:00`, so
    /// both the fractional-seconds and numeric-offset spellings have to parse.
    static func iso8601(_ raw: String?) -> Date? {
        guard let raw = normalized(raw) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// A calendar day (`2026-08-01`) or a full instant, both of which GitHub emits for the same
    /// field. A bare day is anchored at UTC midnight.
    static func calendarDayOrISO8601(_ raw: String?) -> Date? {
        guard let raw = normalized(raw) else { return nil }
        if let instant = iso8601(raw) { return instant }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }

    /// Epoch seconds, where a non-positive value means "no reset is known".
    ///
    /// Codex sends `0` for an unknown reset. Treating that as an instant renders a reset that
    /// happened in 1970, which is exactly the bug the reference's two window mappers disagree on.
    static func epochSeconds(_ value: Int?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    /// Epoch milliseconds, the unit Claude Code stores its token expiry in.
    static func epochMilliseconds(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value / 1000)
    }

    /// A window length, where a non-positive value means "not stated".
    static func windowDuration(seconds: Int?) -> Duration? {
        guard let seconds, seconds > 0 else { return nil }
        return .seconds(seconds)
    }

    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
