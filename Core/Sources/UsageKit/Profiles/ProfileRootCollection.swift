import Foundation

/// The complete, deterministically ordered set of provider configuration roots.
public struct ProfileRootCollection: Sendable, Equatable, Codable {
    public static let currentSchemaVersion = 1

    public private(set) var profiles: [ProfileRoot]

    public init(profiles: [ProfileRoot] = []) throws(ProfileRootValidationError) {
        try Self.validate(profiles)
        self.profiles = profiles
    }

    /// Builds the first-run roots without consulting the process home directory or the file system.
    public static func seeded(homeDirectory: URL) throws(ProfileRootValidationError) -> Self {
        let homePath = try ProfileRoot.normalize(homeDirectory.path(percentEncoded: false))
        return try ProfileRootCollection(
            profiles: [
                ProfileRoot(
                    id: Defaults.claudeID,
                    providerID: ProviderID("claude"),
                    label: "Claude",
                    configurationDirectoryPath: homePath + "/.claude"
                ),
                ProfileRoot(
                    id: Defaults.codexID,
                    providerID: ProviderID("codex"),
                    label: "Codex",
                    configurationDirectoryPath: homePath + "/.codex"
                ),
                ProfileRoot(
                    id: Defaults.copilotCLIID,
                    providerID: ProviderID("copilot"),
                    label: "Copilot CLI",
                    configurationDirectoryPath: homePath + "/.copilot"
                ),
                ProfileRoot(
                    id: Defaults.copilotID,
                    providerID: ProviderID("copilot"),
                    label: "Copilot Editor",
                    configurationDirectoryPath: homePath + "/.config/github-copilot"
                ),
            ]
        )
    }

    @discardableResult
    public mutating func add(
        id: ProfileRootID = ProfileRootID(),
        providerID: ProviderID,
        label: String,
        configurationDirectoryPath: String,
        isEnabled: Bool = true
    ) throws(ProfileRootValidationError) -> ProfileRoot {
        let profile = try ProfileRoot(
            id: id,
            providerID: providerID,
            label: label,
            configurationDirectoryPath: configurationDirectoryPath,
            isEnabled: isEnabled
        )
        var updated = profiles
        updated.append(profile)
        try Self.validate(updated)
        profiles = updated
        return profile
    }

    public mutating func edit(
        id: ProfileRootID,
        label: String,
        configurationDirectoryPath: String,
        isEnabled: Bool
    ) throws(ProfileRootValidationError) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw .profileNotFound(id)
        }
        var updated = profiles
        try updated[index].edit(
            label: label,
            configurationDirectoryPath: configurationDirectoryPath,
            isEnabled: isEnabled
        )
        try Self.validate(updated)
        profiles = updated
    }

    public mutating func setEnabled(
        _ isEnabled: Bool,
        for id: ProfileRootID
    ) throws(ProfileRootValidationError) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw .profileNotFound(id)
        }
        profiles[index].setEnabled(isEnabled)
    }

    public mutating func move(
        id: ProfileRootID,
        to destinationIndex: Int
    ) throws(ProfileRootValidationError) {
        guard let sourceIndex = profiles.firstIndex(where: { $0.id == id }) else {
            throw .profileNotFound(id)
        }
        guard profiles.indices.contains(destinationIndex) else {
            throw .destinationIndexOutOfBounds(destinationIndex)
        }
        let profile = profiles.remove(at: sourceIndex)
        profiles.insert(profile, at: destinationIndex)
    }

    public mutating func remove(id: ProfileRootID) throws(ProfileRootValidationError) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw .profileNotFound(id)
        }
        profiles.remove(at: index)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, profiles
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw ProfileRootCodingError.unsupportedSchemaVersion(version)
        }
        let decodedProfiles = try container.decode([ProfileRoot].self, forKey: .profiles)
        do {
            try self.init(profiles: decodedProfiles)
        } catch let error {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: error.description
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(profiles, forKey: .profiles)
    }

    private static func validate(_ profiles: [ProfileRoot]) throws(ProfileRootValidationError) {
        var ids: Set<ProfileRootID> = []
        var rootsByProvider: [ProviderID: Set<String>] = [:]
        for profile in profiles {
            guard ids.insert(profile.id).inserted else {
                throw .duplicateID(profile.id)
            }
            let comparisonKey = ProfileRoot.duplicateComparisonKey(
                for: profile.configurationDirectoryPath
            )
            let inserted = rootsByProvider[profile.providerID, default: []]
                .insert(comparisonKey)
            guard inserted.inserted else {
                throw .duplicateConfigurationDirectory(
                    providerID: profile.providerID,
                    path: profile.configurationDirectoryPath
                )
            }
        }
    }

    private enum Defaults {
        static let claudeID = ProfileRootID(
            UUID(
                uuid: (
                    0x75, 0x73, 0x61, 0x67, 0x65, 0x00, 0x40, 0x01, 0x80, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x01
                ))
        )
        static let codexID = ProfileRootID(
            UUID(
                uuid: (
                    0x75, 0x73, 0x61, 0x67, 0x65, 0x00, 0x40, 0x01, 0x80, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x02
                ))
        )
        static let copilotID = ProfileRootID(
            UUID(
                uuid: (
                    0x75, 0x73, 0x61, 0x67, 0x65, 0x00, 0x40, 0x01, 0x80, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x03
                ))
        )
        static let copilotCLIID = ProfileRootID(
            UUID(
                uuid: (
                    0x75, 0x73, 0x61, 0x67, 0x65, 0x00, 0x40, 0x01, 0x80, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x04
                ))
        )
    }
}

enum ProfileRootCodingError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(Int)
}
