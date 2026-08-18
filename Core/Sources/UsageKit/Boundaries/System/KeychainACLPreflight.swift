import Darwin
import Foundation
import Security

/// Predicts whether decrypting one file-based Keychain row would need a dialog, before any
/// payload query is issued.
///
/// The no-UI markers and the process-wide suppression lever stop a background read from *showing*
/// its dialog, but only after the Security framework has already decided one was needed: the read
/// is denied, and an `OSStatus` is all that distinguishes a locked keychain from a build the row's
/// ACL does not trust. The row's decrypt ACL states that decision up front — it names the trusted
/// programs and whether the item demands confirmation regardless — and reading it costs one
/// attributes query, which the file-based keychain serves without UI. A background refresh can
/// therefore skip a payload query that is provably going to be refused instead of spending a denied
/// read to find out.
///
/// The SecKeychain ACL API has been deprecated since macOS 10.10 with no replacement that answers
/// this question, and this package builds with warnings as errors, so every call is resolved from
/// the Security framework at runtime — the same treatment `KeychainNoUIPolicy` gives
/// `kSecUseAuthenticationUIFail`. All CF objects travel as raw pointers for the same reason: naming
/// the deprecated types would warn just like calling the functions would.
enum KeychainACLPreflight {
    enum Outcome: Sendable, Equatable {
        case allowed
        case interactionRequired
        /// The ACL could not be read or evaluated. The caller proceeds to the suppressed read,
        /// whose fail-closed behaviour this probe refines but must never replace.
        case undetermined
    }

    /// The judgement over one ACL entry's contents. Pure, so a test can pin the policy without a
    /// Keychain.
    ///
    /// A non-zero prompt selector means the item may demand confirmation based on signature state
    /// a background probe cannot prove safe, so it fails closed. A `nil` application list is an
    /// ACL that does not restrict callers at all. An explicit list requires at least one stored
    /// code requirement to validate against this executable — a path match alone is not enough,
    /// because a legacy ACL can retain an old build's signature at the same path and still prompt.
    static func entryAllows(
        promptSelector: UInt16,
        trustedApplicationValidations: [Bool]?
    ) -> Bool {
        guard promptSelector == 0 else { return false }
        guard let validations = trustedApplicationValidations else { return true }
        return validations.contains(true)
    }

    /// Whether this process can decrypt `item` without UI, judged from the item's own ACL.
    ///
    /// `item` is the `kSecValueRef` of a matched row. Any entry that admits this executable is
    /// enough. When no entry could be read — a dlsym miss, a copy failure, an empty list — the
    /// answer is `.undetermined` rather than a guess in either direction.
    static func check(
        item: AnyObject,
        executablePath: String? = currentExecutablePath
    ) -> Outcome {
        guard let executablePath, let functions = Functions.resolved else { return .undetermined }
        let itemPointer = Unmanaged.passUnretained(item).toOpaque()

        var accessPointer: UnsafeMutableRawPointer?
        guard functions.copyItemAccess(itemPointer, &accessPointer) == errSecSuccess,
            let accessPointer
        else { return .undetermined }
        defer { Unmanaged<AnyObject>.fromOpaque(accessPointer).release() }

        guard
            let listPointer = functions.copyMatchingACLList(
                accessPointer, functions.decryptAuthorizationTag
            )
        else { return .undetermined }
        let aclList = Unmanaged<CFArray>.fromOpaque(listPointer).takeRetainedValue()

        var sawEntry = false
        for index in 0..<CFArrayGetCount(aclList) {
            guard let aclPointer = CFArrayGetValueAtIndex(aclList, index) else { continue }
            guard
                let entry = Self.contents(
                    ofACL: UnsafeMutableRawPointer(mutating: aclPointer),
                    using: functions
                )
            else { continue }
            sawEntry = true
            let validations = entry.applications.map { applications in
                applications.map { application in
                    functions.validateTrustedApplication(application, executablePath)
                        == errSecSuccess
                }
            }
            if Self.entryAllows(
                promptSelector: entry.promptSelector,
                trustedApplicationValidations: validations
            ) {
                return .allowed
            }
        }
        return sawEntry ? .interactionRequired : .undetermined
    }

    /// The running executable, symlinks resolved, which is the identity the ACL judges.
    static let currentExecutablePath: String? =
        Bundle.main.executableURL?
        .resolvingSymlinksInPath()
        .path(percentEncoded: false)

    private struct ACLEntry {
        let promptSelector: UInt16
        /// `nil` when the entry restricts no applications; otherwise the trusted-application
        /// pointers to validate.
        let applications: [UnsafeMutableRawPointer]?
    }

    private static func contents(
        ofACL acl: UnsafeMutableRawPointer,
        using functions: Functions
    ) -> ACLEntry? {
        var applicationsPointer: UnsafeMutableRawPointer?
        var descriptionPointer: UnsafeMutableRawPointer?
        var promptSelector: UInt16 = 0
        guard
            functions.copyACLContents(
                acl, &applicationsPointer, &descriptionPointer, &promptSelector
            ) == errSecSuccess
        else { return nil }
        if let descriptionPointer {
            Unmanaged<AnyObject>.fromOpaque(descriptionPointer).release()
        }
        guard let applicationsPointer else {
            return ACLEntry(promptSelector: promptSelector, applications: nil)
        }
        let applicationList = Unmanaged<CFArray>.fromOpaque(applicationsPointer)
            .takeRetainedValue()
        var applications: [UnsafeMutableRawPointer] = []
        for index in 0..<CFArrayGetCount(applicationList) {
            guard let pointer = CFArrayGetValueAtIndex(applicationList, index) else { continue }
            applications.append(UnsafeMutableRawPointer(mutating: pointer))
        }
        return ACLEntry(promptSelector: promptSelector, applications: applications)
    }

    /// The four deprecated calls and the authorization-tag constant, resolved once.
    ///
    /// Not `Sendable` because the tag is a raw pointer; the `nonisolated(unsafe)` on `resolved`
    /// is sound because the value is written once, before any reader, and never mutated.
    private struct Functions {
        typealias CopyItemAccess =
            @convention(c) (
                UnsafeRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>
            ) -> OSStatus
        typealias CopyMatchingACLList =
            @convention(c) (
                UnsafeRawPointer, UnsafeRawPointer
            ) -> UnsafeMutableRawPointer?
        typealias CopyACLContents =
            @convention(c) (
                UnsafeRawPointer,
                UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                UnsafeMutablePointer<UnsafeMutableRawPointer?>,
                UnsafeMutablePointer<UInt16>
            ) -> OSStatus
        typealias ValidateTrustedApplication =
            @convention(c) (
                UnsafeRawPointer, UnsafePointer<CChar>
            ) -> OSStatus

        let copyItemAccess: CopyItemAccess
        let copyMatchingACLList: CopyMatchingACLList
        let copyACLContents: CopyACLContents
        let validateTrustedApplication: ValidateTrustedApplication
        /// `kSecACLAuthorizationDecrypt`, passed back to `SecAccessCopyMatchingACLList` unretained.
        let decryptAuthorizationTag: UnsafeRawPointer

        nonisolated(unsafe) static let resolved: Functions? = {
            guard
                let handle = dlopen(
                    "/System/Library/Frameworks/Security.framework/Security", RTLD_NOW
                )
            else { return nil }
            guard let copyItemAccess = dlsym(handle, "SecKeychainItemCopyAccess"),
                let copyMatchingACLList = dlsym(handle, "SecAccessCopyMatchingACLList"),
                let copyACLContents = dlsym(handle, "SecACLCopyContents"),
                let validate = dlsym(handle, "SecTrustedApplicationValidateWithPath"),
                let tagSymbol = dlsym(handle, "kSecACLAuthorizationDecrypt"),
                let tag = tagSymbol.assumingMemoryBound(to: UnsafeRawPointer?.self).pointee
            else {
                dlclose(handle)
                return nil
            }
            // The handle stays open for the process lifetime: the resolved pointers below are
            // only valid while it is.
            return Functions(
                copyItemAccess: unsafeBitCast(copyItemAccess, to: CopyItemAccess.self),
                copyMatchingACLList: unsafeBitCast(
                    copyMatchingACLList, to: CopyMatchingACLList.self
                ),
                copyACLContents: unsafeBitCast(copyACLContents, to: CopyACLContents.self),
                validateTrustedApplication: unsafeBitCast(
                    validate, to: ValidateTrustedApplication.self
                ),
                decryptAuthorizationTag: tag
            )
        }()
    }
}
