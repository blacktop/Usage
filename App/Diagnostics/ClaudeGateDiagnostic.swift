import Foundation
import Synchronization
import UsageKit

/// The app half of the Claude metering acceptance gates.
///
/// `--diagnose-claude-keychain` runs Gate A: one enumeration-only query per enabled Claude root,
/// reporting only profile index, match/no-match, and `OSStatus`. `--diagnose-claude-usage
/// --profile-index <n> --source claude-code|setup-token` runs one Gate B leg: one credential
/// resolution and at most one usage request, reported as redacted allowlisted fields.
///
/// Both run from the signed app bundle because the Keychain ACL answers depend on this bundle's own
/// code identity, and both exit before a scene, an `AppModel`, or a refresh exists. Output goes to
/// stdout only — deliberately never to the unified log, where a per-root table would outlive the
/// operator who asked for it.
enum ClaudeGateDiagnostic {
    private static let keychainFlag = "--diagnose-claude-keychain"
    private static let usageFlag = "--diagnose-claude-usage"
    private static let profileIndexOption = "--profile-index"
    private static let sourceOption = "--source"

    enum Invocation: Equatable {
        case keychainAddresses
        case usage(profileIndex: Int, source: ClaudeUsageDiagnosticResult.Source)
        /// A gate flag was present but its arguments were unusable; the launch must not fall
        /// through to the ordinary app.
        case invalid
    }

    /// The gate run `arguments` asks for, or `nil` for an ordinary launch.
    static func invocation(from arguments: [String]) -> Invocation? {
        if arguments.contains(keychainFlag) { return .keychainAddresses }
        guard arguments.contains(usageFlag) else { return nil }
        guard let index = value(after: profileIndexOption, in: arguments).flatMap(Int.init),
            index >= 1,
            let source = value(after: sourceOption, in: arguments)
                .flatMap(ClaudeUsageDiagnosticResult.Source.init(rawValue:))
        else { return .invalid }
        return .usage(profileIndex: index, source: source)
    }

    static func run(_ invocation: Invocation) -> Never {
        switch invocation {
        case .invalid:
            fail(
                "usage: Usage \(usageFlag) \(profileIndexOption) <n> "
                    + "\(sourceOption) claude-code|setup-token",
                code: 2
            )
        case .keychainAddresses:
            // Background policy: Gate A is enumeration-only and must not be able to prompt.
            let context = ProviderContext.system()
            switch blocking({
                try await ClaudeGateDiagnostics.keychainAddressOutcomes(
                    context: context)
            })
            {
            case .success(let outcomes) where outcomes.isEmpty:
                fail("No enabled Claude profile roots are configured.", code: 1)
            case .success(let outcomes):
                finish(lines: ClaudeGateDiagnostics.lines(for: outcomes))
            case .failure(let failure):
                fail(message(for: failure), code: 1)
            }
        case .usage(let profileIndex, let source):
            // The one launch allowed to raise the Keychain approval dialog: the operator asked
            // for this exact read. Scheduled refreshes never construct this policy.
            let context = ProviderContext.system(interaction: UserInitiatedInteractionPolicy())
            switch blocking({
                try await ClaudeGateDiagnostics.usageResult(
                    context: context, profileIndex: profileIndex, source: source)
            })
            {
            case .success(let result):
                finish(lines: [ClaudeGateDiagnostics.line(for: result)])
            case .failure(let failure):
                fail(message(for: failure), code: failureExitCode(for: failure))
            }
        }
    }

    private static func value(after option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func message(for failure: ClaudeGateDiagnosticFailure) -> String {
        switch failure {
        case .storageUnreadable:
            "The configured profile roots could not be read."
        case .profileIndexOutOfRange(let configured):
            "Profile index is out of range: \(configured) Claude root(s) are enabled."
        }
    }

    private static func failureExitCode(for failure: ClaudeGateDiagnosticFailure) -> Int32 {
        switch failure {
        case .storageUnreadable: 1
        case .profileIndexOutOfRange: 2
        }
    }

    private static func finish(lines: [String]) -> Never {
        print(lines.joined(separator: "\n"))
        exit(EXIT_SUCCESS)
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }

    /// Runs one async gate to completion while the main run loop keeps turning.
    ///
    /// The diagnostic executes during `UsageApp.init`, before any scene exists, so there is no
    /// scheduler to hand the work to; pumping the run loop keeps the main actor responsive for
    /// anything the work hops through while this frame waits.
    private static func blocking<T: Sendable>(
        _ work: @escaping @Sendable () async throws -> T
    ) -> Result<T, ClaudeGateDiagnosticFailure> {
        let box = Mutex<Result<T, ClaudeGateDiagnosticFailure>?>(nil)
        Task.detached {
            let outcome: Result<T, ClaudeGateDiagnosticFailure>
            do {
                outcome = .success(try await work())
            } catch let failure as ClaudeGateDiagnosticFailure {
                outcome = .failure(failure)
            } catch {
                // The gates throw only their own failure type; anything else is a storage-shaped
                // surprise and is reported as the closest truthful category.
                outcome = .failure(.storageUnreadable)
            }
            box.withLock { $0 = outcome }
        }
        while true {
            if let outcome = box.withLock({ $0 }) { return outcome }
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
        }
    }
}
