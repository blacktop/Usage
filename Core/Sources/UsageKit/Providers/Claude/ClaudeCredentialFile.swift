import Foundation

/// Non-secret facts from a Claude Code credential document.
///
/// The same shape is stored in the Keychain item and in `~/.claude/.credentials.json`. The access
/// token is checked only for presence and is not retained.
struct ClaudeCredentialMetadata: Sendable, Hashable {
    let subscriptionType: String?
    let rateLimitTier: String?

    var planLabel: String? {
        ClaudePlanLabel.make(subscriptionType: subscriptionType, rateLimitTier: rateLimitTier)
    }
}

extension ClaudeCredentialMetadata: ProviderCredentialMetadata {}

/// Reader for Claude Code's credential document.
enum ClaudeCredentialFile {
    /// Where the bearer token sits inside the document, for `CredentialSource` to resolve.
    static let secretPath = ["claudeAiOauth", "accessToken"]
    /// The one document Claude discovery reads, directly below a configured root.
    static let documentName = ".credentials.json"

    static func url(root: URL) -> URL {
        root.appending(path: documentName, directoryHint: .notDirectory)
    }

    /// Parses the document, requiring a subscription OAuth token.
    ///
    /// A document holding only `mcpOAuth` is a real Claude Code 2.1.x state, not corruption: the
    /// CLI has MCP server tokens but no subscription login. It is reported as a missing credential
    /// rather than a malformed one, because the fix is to sign in, not to repair a file.
    static func parse(
        _ data: Data, kind: CredentialLocator.Kind
    ) throws(UsageError)
        -> ClaudeCredentialMetadata
    {
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else {
            throw UsageError.decodingFailure(field: "credentials.json")
        }
        guard document.hasAccessToken else {
            throw UsageError.credentialUnavailable(kind: kind)
        }
        return ClaudeCredentialMetadata(
            subscriptionType: document.subscriptionType,
            rateLimitTier: document.rateLimitTier
        )
    }

    private struct Document: Decodable {
        let hasAccessToken: Bool
        let subscriptionType: String?
        let rateLimitTier: String?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            let oauth = root.nested("claudeAiOauth")
            hasAccessToken = oauth?.trimmedString("accessToken") != nil
            subscriptionType = oauth?.trimmedString("subscriptionType")
            rateLimitTier = oauth?.trimmedString("rateLimitTier")
        }
    }
}

/// Renders Claude's plan label from the credential, which is the only place it appears.
///
/// The usage response carries no plan field at all.
enum ClaudePlanLabel {
    private static let tiers = ["max", "pro", "team", "enterprise", "ultra"]

    static func make(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let tier = tier(in: subscriptionType) ?? tier(in: rateLimitTier) else { return nil }
        guard tier == "max", let multiplier = maxMultiplier(in: rateLimitTier) else {
            return "Claude \(tier.capitalized)"
        }
        return "Claude Max \(multiplier)"
    }

    private static func tier(in raw: String?) -> String? {
        words(in: raw).first { tiers.contains($0) }
    }

    /// The `20x` in `default_claude_max_20x`.
    private static func maxMultiplier(in raw: String?) -> String? {
        let words = words(in: raw)
        guard let index = words.firstIndex(of: "max"), words.indices.contains(index + 1) else {
            return nil
        }
        let candidate = words[index + 1]
        guard candidate.hasSuffix("x"), candidate.count > 1,
            candidate.dropLast().allSatisfy(\.isNumber)
        else { return nil }
        return candidate
    }

    private static func words(in raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}
