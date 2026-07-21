/// Whether the current context may issue a credential query that can present system UI.
///
/// A background refresh must fail closed rather than raise a Keychain password prompt; only an
/// explicit user action in Settings runs under a policy that allows it.
public protocol InteractionPolicy: Sendable {
    var allowsCredentialUI: Bool { get }
}

/// The policy every scheduled refresh runs under.
public struct BackgroundInteractionPolicy: InteractionPolicy {
    public init() {}
    public let allowsCredentialUI = false
}

/// The policy an explicit user action in Settings runs under.
public struct UserInitiatedInteractionPolicy: InteractionPolicy {
    public init() {}
    public let allowsCredentialUI = true
}
