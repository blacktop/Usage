import Foundation

/// A non-secret configuration directory for one provider profile.
public struct ProfileRoot: Sendable, Hashable, Codable, Identifiable {
    public let id: ProfileRootID
    public let providerID: ProviderID
    public private(set) var label: String
    public private(set) var configurationDirectoryPath: String
    public private(set) var isEnabled: Bool

    public init(
        id: ProfileRootID = ProfileRootID(),
        providerID: ProviderID,
        label: String,
        configurationDirectoryPath: String,
        isEnabled: Bool = true
    ) throws(ProfileRootValidationError) {
        let normalizedPath = try Self.normalize(configurationDirectoryPath)
        self.id = id
        self.providerID = providerID
        self.label = Self.normalizeLabel(label, configurationDirectoryPath: normalizedPath)
        self.configurationDirectoryPath = normalizedPath
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, label, configurationDirectoryPath, isEnabled
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(ProfileRootID.self, forKey: .id)
        let providerID = try container.decode(ProviderID.self, forKey: .providerID)
        let label = try container.decode(String.self, forKey: .label)
        let configurationDirectoryPath = try container.decode(
            String.self,
            forKey: .configurationDirectoryPath
        )
        let isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        do {
            try self.init(
                id: id,
                providerID: providerID,
                label: label,
                configurationDirectoryPath: configurationDirectoryPath,
                isEnabled: isEnabled
            )
        } catch let error {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: error.description
                )
            )
        }
    }

    mutating func edit(
        label: String,
        configurationDirectoryPath: String,
        isEnabled: Bool
    ) throws(ProfileRootValidationError) {
        let normalizedPath = try Self.normalize(configurationDirectoryPath)
        self.label = Self.normalizeLabel(label, configurationDirectoryPath: normalizedPath)
        self.configurationDirectoryPath = normalizedPath
        self.isEnabled = isEnabled
    }

    mutating func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    static func normalize(_ path: String) throws(ProfileRootValidationError) -> String {
        guard path.hasPrefix("/") else {
            throw .configurationDirectoryMustBeAbsolute
        }

        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty {
                    components.removeLast()
                }
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    /// Produces a deterministic duplicate-comparison key without changing the stored path.
    /// A fixed POSIX locale makes case folding host-independent, while canonical composition
    /// makes canonically equivalent Unicode paths compare equally.
    static func duplicateComparisonKey(for normalizedPath: String) -> String {
        normalizedPath
            .precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func normalizeLabel(
        _ label: String,
        configurationDirectoryPath: String
    ) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return trimmed }
        return configurationDirectoryPath.split(separator: "/").last.map(String.init) ?? "/"
    }
}
