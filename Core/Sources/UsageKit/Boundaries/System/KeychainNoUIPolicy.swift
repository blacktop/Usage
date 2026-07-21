import Darwin
import Foundation
import LocalAuthentication
import Security

/// Marks a Keychain query as one that must fail rather than present UI.
///
/// Two markers, because neither is sufficient alone on macOS. `LAContext.interactionNotAllowed`
/// covers the modern authentication path, and the legacy `kSecUseAuthenticationUI` fail policy
/// covers the file-based login keychain, whose Allow/Deny dialog predates `LAContext` and still
/// appears without it.
///
/// The legacy constant is deprecated, and this package builds with warnings as errors, so its value
/// is resolved from the Security framework at runtime instead of referenced at compile time. A
/// failed lookup falls back to the constant's own published value rather than dropping the marker.
struct KeychainNoUIPolicy: Sendable {
    private static let publishedUIFailValue = "u_AuthUIF"
    private static let securityFrameworkPath =
        "/System/Library/Frameworks/Security.framework/Security"

    private let legacyUIFailValue: String

    init() {
        legacyUIFailValue = Self.resolveLegacyUIFailValue()
    }

    /// `query` with both no-UI markers applied.
    func applied(to query: [String: Any]) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var marked = query
        marked[kSecUseAuthenticationContext as String] = context
        marked[kSecUseAuthenticationUI as String] = legacyUIFailValue as CFString
        return marked
    }

    /// The value the legacy marker was resolved to, so a test can prove the marker is real rather
    /// than silently absent.
    var resolvedUIFailValue: String { legacyUIFailValue }

    private static func resolveLegacyUIFailValue() -> String {
        guard let handle = dlopen(securityFrameworkPath, RTLD_NOW) else {
            return publishedUIFailValue
        }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return publishedUIFailValue
        }
        let value = symbol.assumingMemoryBound(to: CFString?.self).pointee as String?
        return value ?? publishedUIFailValue
    }
}
