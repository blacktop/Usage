import Foundation

/// Body of `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Undocumented, unversioned, and gated on a dated beta header. The shape has already changed more
/// than once — flat `seven_day_*` members were joined by a `limits` array, and the model-scoped
/// members now arrive null on newer accounts — so every member is optional.
struct ClaudeUsageResponse: Decodable, Sendable {
    let fiveHour: ClaudeWindowSnapshot?
    let sevenDay: ClaudeWindowSnapshot?
    let sevenDayOAuthApps: ClaudeWindowSnapshot?
    let sevenDayOpus: ClaudeWindowSnapshot?
    let sevenDaySonnet: ClaudeWindowSnapshot?
    let sevenDayRoutines: ClaudeWindowSnapshot?
    let limits: [ClaudeLimitEntry]
    let extraUsage: ClaudeExtraUsage?
    let hadDecodeFailure: Bool

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        var failed = false
        func window(_ name: String) -> ClaudeWindowSnapshot? {
            let value = root.lossy(ClaudeWindowSnapshot.self, forKey: AnyCodingKey(name))
            failed = failed || value.failed
            return value.value
        }
        fiveHour = window("five_hour")
        sevenDay = window("seven_day")
        sevenDayOAuthApps = window("seven_day_oauth_apps")
        sevenDayOpus = window("seven_day_opus")
        sevenDaySonnet = window("seven_day_sonnet")
        sevenDayRoutines = window("seven_day_routines")

        let limits = root.lossyArray(ClaudeLimitEntry.self, forKey: AnyCodingKey("limits"))
        let extraUsage = root.lossy(ClaudeExtraUsage.self, forKey: AnyCodingKey("extra_usage"))
        self.limits = limits.value ?? []
        self.extraUsage = extraUsage.value
        hadDecodeFailure = failed || limits.failed || extraUsage.failed
    }

    static func decode(_ data: Data) throws(UsageError) -> ClaudeUsageResponse {
        guard let response = try? JSONDecoder().decode(ClaudeUsageResponse.self, from: data) else {
            throw UsageError.decodingFailure(field: "oauth.usage")
        }
        return response
    }
}

/// A percentage window. `utilization` is a percent in `0…100` and may legitimately exceed 100.
struct ClaudeWindowSnapshot: Decodable, Sendable {
    let utilization: Double
    let resetsAt: Date?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        guard let utilization = root.lenientDecimal("utilization") else {
            throw DecodingError.dataCorruptedError(
                forKey: AnyCodingKey("utilization"),
                in: root,
                debugDescription: "A window without a usable percentage carries no information."
            )
        }
        self.utilization = Double(truncating: utilization as NSDecimalNumber)
        resetsAt = ProviderDates.iso8601(root.trimmedString("resets_at"))
    }
}

/// One row of the newer `limits` array.
///
/// `is_active` is deliberately not read. Enforceable scoped limits have been observed reporting
/// `false`, so filtering on it silently drops real limits.
struct ClaudeLimitEntry: Decodable, Sendable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: Date?
    let modelID: String?
    let modelDisplayName: String?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        kind = root.trimmedString("kind")
        group = root.trimmedString("group")
        percent = root.lenientDecimal("percent").map { Double(truncating: $0 as NSDecimalNumber) }
        resetsAt = ProviderDates.iso8601(root.trimmedString("resets_at"))
        let model = root.nested("scope")?.nested("model")
        modelID = model?.trimmedString("id")
        modelDisplayName = model?.trimmedString("display_name")
    }
}

/// Pay-as-you-go balance. Amounts arrive in minor units (cents).
struct ClaudeExtraUsage: Decodable, Sendable {
    let isEnabled: Bool
    let monthlyLimitMinorUnits: Decimal?
    let usedCreditsMinorUnits: Decimal?
    let currency: String?

    init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: AnyCodingKey.self)
        isEnabled = root.lenientBool("is_enabled", default: false)
        monthlyLimitMinorUnits = root.lenientDecimal("monthly_limit")
        usedCreditsMinorUnits = root.lenientDecimal("used_credits")
        currency = root.trimmedString("currency")
    }
}
