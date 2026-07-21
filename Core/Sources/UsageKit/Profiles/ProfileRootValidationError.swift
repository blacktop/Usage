/// A recoverable violation of the profile-root collection's invariants.
public enum ProfileRootValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case configurationDirectoryMustBeAbsolute
    case duplicateID(ProfileRootID)
    case duplicateConfigurationDirectory(providerID: ProviderID, path: String)
    case profileNotFound(ProfileRootID)
    case destinationIndexOutOfBounds(Int)

    public var description: String {
        switch self {
        case .configurationDirectoryMustBeAbsolute:
            "Configuration directory paths must be absolute."
        case .duplicateID(let id):
            "Profile root ID \(id) occurs more than once."
        case .duplicateConfigurationDirectory(let providerID, let path):
            "Provider \(providerID) has more than one profile root at \(path)."
        case .profileNotFound(let id):
            "Profile root \(id) does not exist."
        case .destinationIndexOutOfBounds(let index):
            "Profile root destination index \(index) is out of bounds."
        }
    }
}
