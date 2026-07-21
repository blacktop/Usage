import Foundation

extension Duration {
    /// The duration in seconds.
    ///
    /// Lossy below the attosecond boundary of `Double`, which is irrelevant here: every schedule in
    /// Usage is expressed in whole seconds and every comparison against a `Date` goes through
    /// `TimeInterval` anyway.
    var totalSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension Date {
    /// The instant `duration` after this one.
    func adding(_ duration: Duration) -> Date {
        addingTimeInterval(duration.totalSeconds)
    }
}
