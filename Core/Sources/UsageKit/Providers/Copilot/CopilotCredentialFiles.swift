import Foundation

/// One GitHub Copilot credential entry, described without its token.
struct CopilotCredentialSlot: Sendable, Hashable {
    /// File the entry came from, e.g. `apps.json`.
    let fileName: String
    /// The entry's own key in that file, e.g. `Iv1.b507a08c87ecfe98:github.com`.
    let mapKey: String
    /// Which member of the entry holds the token, so `CredentialSource` can address it.
    let tokenField: String
    /// Normalised GitHub host the token belongs to.
    let host: String
}

/// Reader for the credential files the Copilot editor plugin and CLI keep in their configuration
/// directory.
///
/// Read-only, and shape-tolerant on purpose: these files belong to tools that version
/// independently of Usage, and their internal key names are not part of any published contract.
enum CopilotCredentialFiles {
    static let defaultHost = "github.com"
    /// Candidate documents in precedence order, each read directly below a configured root: the
    /// current editor-plugin store, its predecessor, and the standalone CLI's store.
    static let fileNames = ["apps.json", "hosts.json", "oauth.json"]
    /// Member names that have been observed holding the token, tried in this order.
    static let tokenFields = ["oauth_token", "access_token", "token"]

    static func url(root: URL, fileName: String) -> URL {
        root.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Parses one credential file into slots, dropping only the entries that are unusable.
    ///
    /// Entry order is by key so discovery is deterministic, and an entry with no token contributes
    /// nothing rather than failing its siblings.
    static func slots(in data: Data, fileName: String) -> [CopilotCredentialSlot] {
        guard
            let entries = try? JSONDecoder().decode([String: LossyElement<Entry>].self, from: data)
        else { return [] }
        return entries.keys.sorted().compactMap { key in
            guard let entry = entries[key]?.value, let tokenField = entry.tokenField else {
                return nil
            }
            return CopilotCredentialSlot(
                fileName: fileName,
                mapKey: key,
                tokenField: tokenField,
                host: host(forKey: key, fileName: fileName)
            )
        }
    }

    /// `apps.json` keys are `<githubAppClientID>:<host>`; the other two are keyed by host alone.
    static func host(forKey key: String, fileName: String) -> String {
        guard fileName == "apps.json", let separator = key.lastIndex(of: ":") else {
            return normalizedHost(key)
        }
        return normalizedHost(String(key[key.index(after: separator)...]))
    }

    /// Strips a scheme and path, lowercases, and trims stray dots.
    static func normalizedHost(_ raw: String?) -> String {
        guard var host = raw?.trimmedNonEmpty?.lowercased() else { return defaultHost }
        if let scheme = host.range(of: "://") { host = String(host[scheme.upperBound...]) }
        host = String(host.prefix { $0 != "/" })
        while host.hasPrefix(".") { host.removeFirst() }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? defaultHost : host
    }

    /// The REST host for a GitHub host: `github.com` is served from `api.github.com`, and an
    /// enterprise host from `api.<host>`.
    static func apiHost(for host: String) -> String {
        let normalized = normalizedHost(host)
        if normalized == defaultHost { return "api.\(defaultHost)" }
        if normalized.hasPrefix("api.") { return normalized }
        return "api.\(normalized)"
    }

    /// Whether a string is a bare authority that is safe to interpolate into a URL.
    ///
    /// The host comes from a key in a file another tool owns, and the request built from it carries
    /// a live GitHub token. `userinfo@host` is the dangerous shape — Foundation reads
    /// `https://api.ghe.corp@evil.example/…` as a request to `evil.example` — and `?`, `#`, and a
    /// path do the same job by a different route. Only dot-separated alphanumeric-and-hyphen labels
    /// with an optional numeric port are accepted; everything else is refused rather than repaired.
    static func isBareAuthority(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first, !host.isEmpty, host.count <= 253 else {
            return false
        }
        if parts.count == 2 {
            let port = parts[1]
            guard !port.isEmpty, port.allSatisfy(\.isASCII), port.allSatisfy(\.isNumber) else {
                return false
            }
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy(isLabel)
    }

    private static func isLabel(_ label: Substring) -> Bool {
        guard !label.isEmpty, label.count <= 63 else { return false }
        return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    /// Which member of an entry holds its token. Nothing else is read: the entry's GitHub login
    /// is not, because a configured root's label is what names the account.
    private struct Entry: Decodable, Sendable {
        let tokenField: String?

        init(from decoder: any Decoder) throws {
            let root = try decoder.container(keyedBy: AnyCodingKey.self)
            tokenField = CopilotCredentialFiles.tokenFields.first {
                root.trimmedString($0) != nil
            }
        }
    }
}
