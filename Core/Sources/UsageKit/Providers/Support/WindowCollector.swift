/// Accumulates windows while enforcing the report's uniqueness rule as they arrive.
///
/// `UsageReport` rejects duplicate `WindowID`s, which is right for a stored value but wrong as a
/// response to a provider that repeats an identifier: losing the whole report to salvage nothing is
/// worse than dropping the later duplicate. Collecting through this type keeps the composition
/// rules of every provider's `WindowID` under one test.
struct WindowCollector {
    private(set) var windows: [UsageWindow] = []
    private var seen: Set<WindowID> = []

    mutating func add(_ window: UsageWindow?) {
        guard let window, seen.insert(window.id).inserted else { return }
        windows.append(window)
    }
}

/// Slug used as the `feature` component of an `additional:` window identifier.
///
/// Lowercased, with every run of non-alphanumerics collapsed to a single `-`. The identifier itself
/// percent-escapes anything unexpected, so this exists to keep identifiers readable and to make two
/// spellings of one feature name converge — not as a security control.
enum FeatureSlug {
    static func make(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var out = ""
        var pendingSeparator = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
        }
        return out.isEmpty ? nil : out
    }
}
