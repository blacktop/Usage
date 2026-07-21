import CryptoKit
import Foundation

/// Reproduces the profile-directory hashes used by the provider CLIs for Keychain names.
///
/// Both CLIs hash the canonical absolute configuration path directly. This is intentionally not a
/// `DomainDigest`: compatibility with names another process already wrote is the whole contract.
enum ProfileKeychainName {
    static func pathHash(root: URL, length: Int) -> String {
        var path =
            root.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        let digest = Hex.lowercased(SHA256.hash(data: Data(path.utf8)))
        return String(digest.prefix(length))
    }
}
