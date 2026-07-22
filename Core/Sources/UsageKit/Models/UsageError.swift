import Foundation

/// A name of a field in a provider response or in one of our own models.
///
/// The raw string is sanitised on the way in — everything outside `[A-Za-z0-9._[]]` is dropped and
/// the result is truncated. That is defence in depth, not the primary control: `UsageError.Reason`
/// has no free-form payload case at all, so a response body has nowhere to go in the first place.
public struct FieldName:
    Sendable, Hashable, Codable, CustomStringConvertible, ExpressibleByStringLiteral
{
    private static let maximumLength = 64

    public let rawValue: String
    public var description: String { rawValue }

    public init(_ raw: String) {
        let kept = raw.unicodeScalars.filter(Self.isAllowed).prefix(Self.maximumLength)
        let sanitised = String(String.UnicodeScalarView(kept))
        rawValue = sanitised.isEmpty ? "unknown" : sanitised
    }

    public init(stringLiteral value: String) {
        self.init(value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "[", "]": true
        default: false
        }
    }
}

/// The rule a rejected value violated. Carries no value, only the rule.
public enum ValidationRule: String, Sendable, Hashable, Codable, CaseIterable {
    case finite
    case nonNegative
    case consistent
    case currencyCode
    case unique

    var explanation: String {
        switch self {
        case .finite: "must be a finite number"
        case .nonNegative: "must not be negative"
        case .consistent: "is inconsistent with its limit"
        case .currencyCode: "must be a three-letter currency code"
        case .unique: "must be unique"
        }
    }
}

/// The one error type that reaches store state, CLI JSON, notifications, and logs.
///
/// It is redacted by construction: `Reason` enumerates every fact we are willing to surface, and
/// none of those cases can hold a response body, an authorization header, a credential path, or a
/// raw provider payload.
public struct UsageError: Error, Sendable, Hashable, Codable, CustomStringConvertible {
    /// The behavioural class of the failure, which decides what the UI offers the user.
    public enum Category: String, Sendable, Hashable, Codable, CaseIterable {
        case authenticationExpired
        case credentialUnavailable
        case interactionRequired
        case rateLimited
        case network
        case malformedResponse
        case invalidRequest
        case serverError
        case cancelled
        case providerUnavailable
    }

    /// When and how widely a retry is worth attempting.
    public struct RetryAdvice: Sendable, Hashable, Codable {
        /// Which schedule the delay applies to. Defaults to the account, because a
        /// provider-wide cooldown needs positive evidence from the provider contract.
        public enum Scope: String, Sendable, Hashable, Codable, CaseIterable {
            case account
            case provider
        }

        public let delay: Duration
        public let scope: Scope

        public init(delay: Duration, scope: Scope = .account) {
            self.delay = delay
            self.scope = scope
        }
    }

    /// Everything we are willing to say about a failure.
    public enum Reason: Sendable, Hashable, Codable {
        case transportFailure
        case httpStatus(code: Int)
        case decodingFailure(field: FieldName)
        case invalidValue(field: FieldName, rule: ValidationRule)
        case credentialUnavailable(kind: CredentialLocator.Kind)
        case interactionForbidden
        case cancelled
        case providerUnavailable
    }

    public let category: Category
    public let reason: Reason
    public let retry: RetryAdvice?
    /// Set by the provider when the failure is one only the owning agent can clear.
    public let reauthentication: ReauthAction?

    public init(
        category: Category,
        reason: Reason,
        retry: RetryAdvice? = nil,
        reauthentication: ReauthAction? = nil
    ) {
        self.category = category
        self.reason = reason
        self.retry = retry
        self.reauthentication = reauthentication
    }

    /// Redacted, user-facing text. Safe to render, notify with, log, and encode.
    public var message: String {
        switch reason {
        case .transportFailure:
            "Could not reach the provider."
        case .httpStatus(let code):
            "The provider returned HTTP \(code)."
        case .decodingFailure(let field):
            "The provider response could not be read (field \(field))."
        case .invalidValue(let field, let rule):
            "The provider reported an unusable value: \(field) \(rule.explanation)."
        case .credentialUnavailable(let kind):
            "No usable credential was found in the \(kind.noun)."
        case .interactionForbidden:
            "This credential needs your approval in Settings before it can be read."
        case .cancelled:
            "The refresh was cancelled."
        case .providerUnavailable:
            "This provider is not available on this machine."
        }
    }

    public var description: String { "\(category.rawValue): \(message)" }

    /// Whether an explicit, user-initiated Keychain read is the recovery action this error names.
    ///
    /// A genuinely absent or malformed credential stays `.credentialUnavailable`: prompting cannot
    /// repair its payload and must not be presented as if it could.
    public var requiresCredentialApproval: Bool {
        reason == .interactionForbidden
    }
}

extension UsageError {
    /// A copy carrying the instruction that clears this failure.
    ///
    /// Providers attach their own action rather than the error type inferring one, because only the
    /// provider knows which agent owns the credential behind a 401.
    public func offering(_ action: ReauthAction) -> UsageError {
        UsageError(category: category, reason: reason, retry: retry, reauthentication: action)
    }

    /// Any thrown value as the one error type the rest of Usage handles.
    ///
    /// `Provider` is an open protocol and every boundary call is `async throws`, so cancellation
    /// and an undeclared error both need somewhere honest to land. Anything unrecognised escaped
    /// from an I/O boundary, which is what `.transportFailure` describes.
    public static func normalized(_ error: any Error) -> UsageError {
        switch error {
        case let usage as UsageError: usage
        case is CancellationError: .cancelled()
        default: .transportFailure()
        }
    }

    public static func transportFailure() -> UsageError {
        UsageError(category: .network, reason: .transportFailure)
    }

    public static func decodingFailure(field: FieldName) -> UsageError {
        UsageError(category: .malformedResponse, reason: .decodingFailure(field: field))
    }

    public static func invalidValue(field: FieldName, rule: ValidationRule) -> UsageError {
        UsageError(category: .malformedResponse, reason: .invalidValue(field: field, rule: rule))
    }

    public static func credentialUnavailable(kind: CredentialLocator.Kind) -> UsageError {
        UsageError(category: .credentialUnavailable, reason: .credentialUnavailable(kind: kind))
    }

    public static func interactionForbidden() -> UsageError {
        UsageError(category: .interactionRequired, reason: .interactionForbidden)
    }

    public static func cancelled() -> UsageError {
        UsageError(category: .cancelled, reason: .cancelled)
    }

    public static func providerUnavailable() -> UsageError {
        UsageError(category: .providerUnavailable, reason: .providerUnavailable)
    }

    /// Builds a redacted error from a non-success response.
    ///
    /// Only the status code and `Retry-After` are read. The body and every other header are
    /// discarded here and never stored. Passing `now` additionally accepts the HTTP-date form of
    /// `Retry-After`, which servers use as freely as delta-seconds.
    public static func from(
        _ response: HTTPResponse,
        category: Category? = nil,
        now: Date? = nil
    ) -> UsageError {
        UsageError(
            category: category ?? self.category(forStatus: response.status),
            reason: .httpStatus(code: response.status),
            retry: retryAdvice(from: response, now: now)
        )
    }

    private static func retryAdvice(from response: HTTPResponse, now: Date?) -> RetryAdvice? {
        guard
            let raw = response.headerValue("Retry-After")?
                .trimmingCharacters(in: .whitespaces),
            !raw.isEmpty
        else { return nil }
        if let seconds = Int(raw) {
            return RetryAdvice(delay: .seconds(max(0, seconds)), scope: .account)
        }
        guard let now, let date = HTTPDate.parse(raw) else { return nil }
        return RetryAdvice(
            delay: .seconds(max(0, Int(date.timeIntervalSince(now).rounded(.up)))),
            scope: .account
        )
    }

    private static func category(forStatus status: Int) -> Category {
        switch status {
        case 401, 403: .authenticationExpired
        case 429: .rateLimited
        case 500...599: .serverError
        default: .invalidRequest
        }
    }
}
