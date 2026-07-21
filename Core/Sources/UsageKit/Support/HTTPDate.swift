import Foundation

/// The RFC 9110 IMF-fixdate form of `Retry-After`, which servers use as freely as delta-seconds.
enum HTTPDate {
    static func parse(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: raw)
    }
}
