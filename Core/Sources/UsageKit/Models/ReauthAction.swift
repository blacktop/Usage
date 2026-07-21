/// What the owning agent's user must do to restore a credential Usage cannot repair itself.
///
/// Usage is read-only over every agent credential, so a missing or expired one is not a transient
/// failure it can retry out of — it is a state only the owning CLI or application can leave. This
/// carries that instruction to the surface showing the failure.
///
/// Both members are provider-authored constants. Nothing derived from a credential, a response
/// body, or a filesystem path is allowed in, which is what keeps an error carrying one safe to
/// render, notify with, encode, and log.
public struct ReauthAction: Sendable, Hashable, Codable {
    /// One sentence naming the agent that owns the credential and what it has to be told to do.
    public let summary: String
    /// Command the user runs themselves. `nil` when the agent reauthenticates through its own UI
    /// rather than a CLI.
    public let command: String?

    public init(summary: String, command: String? = nil) {
        self.summary = summary
        self.command = command
    }
}
