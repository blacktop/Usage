import Foundation

/// The one rule for turning a stored credential payload into the secret a locator names.
///
/// Both production sources use it, so "where the token lives" is answered identically whether the
/// bytes came off the disk or out of the Keychain. Nothing here is provider-specific: the locator's
/// `path` supplies every provider-shaped decision.
enum CredentialDocument {
    /// The secret `path` addresses inside `payload`.
    ///
    /// An empty path means the payload *is* the secret. Otherwise the payload must be a JSON object
    /// and every component must resolve to a nested object, ending on a non-empty string. Anything
    /// else fails closed: a payload whose shape we cannot confirm is never guessed at and never
    /// sent as a bearer token.
    static func secret(
        in payload: Data,
        at path: [String],
        kind: CredentialLocator.Kind
    ) throws(UsageError) -> String {
        guard !path.isEmpty else {
            guard let secret = String(data: payload, encoding: .utf8)?.trimmedNonEmpty else {
                throw UsageError.credentialUnavailable(kind: kind)
            }
            return secret
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: payload),
            let secret = walk(root, path: path)
        else {
            throw UsageError.credentialUnavailable(kind: kind)
        }
        return secret
    }

    private static func walk(_ root: Any, path: [String]) -> String? {
        var node = root
        for component in path {
            guard let object = node as? [String: Any], let next = object[component] else {
                return nil
            }
            node = next
        }
        return (node as? String)?.trimmedNonEmpty
    }
}
