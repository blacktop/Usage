import UsageKit

/// Forwards every refresh event to each sink, in order.
///
/// The coordinator takes exactly one sink; this is how the store and the credential-approval
/// notifier both hear the same stream without either knowing the other exists.
///
/// `nonisolated` opts out of the target's MainActor default: forwarding owns no state, so it adds
/// no main-thread hop and each sink runs under its own isolation.
nonisolated struct RefreshEventFanOut: RefreshEventSink {
    let sinks: [any RefreshEventSink]

    func receive(_ event: RefreshEvent) async {
        for sink in sinks {
            await sink.receive(event)
        }
    }
}
