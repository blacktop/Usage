import Foundation

/// Body of `GET https://chatgpt.com/backend-api/wham/usage`.
///
/// The endpoint is undocumented and unversioned, so every member is optional and every array is
/// per-element lossy: a shape change has to degrade to a partial report, never to a total failure.
struct CodexUsageResponse: Decodable, Sendable {
    let planType: String?
    let rateLimit: CodexRateLimit?
    let credits: CodexCredits?
    let additionalRateLimits: [CodexAdditionalRateLimit]
    /// True when at least one present subtree could not be read, so the report is partial.
    let hadDecodeFailure: Bool

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        planType = root.trimmedString("plan_type", "planType")
        let rateLimit = root.lossy(CodexRateLimit.self, forKey: AnyCodingKey("rate_limit"))
        let credits = root.lossy(CodexCredits.self, forKey: AnyCodingKey("credits"))
        let additional = root.lossyArray(
            CodexAdditionalRateLimit.self,
            forKey: AnyCodingKey("additional_rate_limits")
        )
        self.rateLimit = rateLimit.value
        self.credits = credits.value
        additionalRateLimits = additional.value ?? []
        hadDecodeFailure =
            rateLimit.failed || credits.failed || additional.failed
            || rateLimit.value?.hadDecodeFailure == true
            || additionalRateLimits.contains { $0.rateLimit?.hadDecodeFailure == true }
    }

    static func decode(_ data: Data) throws(UsageError) -> CodexUsageResponse {
        guard let response = try? JSONDecoder().decode(CodexUsageResponse.self, from: data) else {
            throw UsageError.decodingFailure(field: "wham.usage")
        }
        return response
    }
}

/// A `rate_limit` object, at the top level or inside one `additional_rate_limits` entry.
///
/// Undocumented siblings such as `allowed`, `limit_reached`, and `reset_after_seconds` appear here
/// in real payloads and are ignored.
struct CodexRateLimit: Decodable, Sendable {
    let primaryWindow: CodexWindowSnapshot?
    let secondaryWindow: CodexWindowSnapshot?
    let hadDecodeFailure: Bool

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        let primary = root.lossy(CodexWindowSnapshot.self, forKey: AnyCodingKey("primary_window"))
        let secondary = root.lossy(
            CodexWindowSnapshot.self,
            forKey: AnyCodingKey("secondary_window")
        )
        primaryWindow = primary.value
        secondaryWindow = secondary.value
        hadDecodeFailure = primary.failed || secondary.failed
    }
}

/// One window. `used_percent` is the only member we insist on: a percentage with no stated reset is
/// still worth showing, and dropping it would lose the account's headline number.
struct CodexWindowSnapshot: Decodable, Sendable {
    let usedPercent: Int
    let resetAt: Int?
    let limitWindowSeconds: Int?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let usedPercent = root.lenientInt("used_percent", "usedPercent") else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyCodingKey("used_percent"),
                in: root,
                debugDescription: "A window without a usable percentage carries no information."
            )
        }
        self.usedPercent = usedPercent
        resetAt = root.lenientInt("reset_at", "resetAt")
        limitWindowSeconds = root.lenientInt("limit_window_seconds", "limitWindowSeconds")
    }
}

/// A separately metered limit, such as a model-specific allowance.
struct CodexAdditionalRateLimit: Decodable, Sendable {
    let limitName: String?
    let meteredFeature: String?
    let rateLimit: CodexRateLimit?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        limitName = root.trimmedString("limit_name", "limitName")
        meteredFeature = root.trimmedString("metered_feature", "meteredFeature")
        rateLimit = root.lossy(CodexRateLimit.self, forKey: AnyCodingKey("rate_limit")).value
    }
}

/// Prepaid balance. The unit is provider-defined: nothing in the payload names a currency.
struct CodexCredits: Decodable, Sendable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Decimal?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        hasCredits = root.lenientBool("has_credits", "hasCredits", default: false)
        unlimited = root.lenientBool("unlimited", default: false)
        balance = root.lenientDecimal("balance")
    }
}
