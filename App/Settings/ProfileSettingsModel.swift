import AppKit
import Foundation
import Observation
import UsageKit

/// The provider-folder editor's whole state: the rows Settings renders, the one error it shows, and
/// the four mutations a user can make.
///
/// Every mutation goes through the same three steps — apply to the last collection that actually
/// persisted, save, and only then adopt it. A rejected edit and a failed save are the same thing to
/// a reader: the rows on screen are still the ones in storage.
///
/// Nothing here opens a credential. The only thing this asks the file system is whether a document
/// a provider is known to read exists below a configured root, and the only thing it stores about a
/// folder the user picked is that folder's path.
@Observable
@MainActor
final class ProfileSettingsModel {
    /// One configured root as a row, paired with whether the provider's document is there.
    struct RootRow: Identifiable, Equatable {
        let profile: ProfileRoot
        let hasCredentialDocument: Bool

        var id: ProfileRootID { profile.id }
    }

    /// One provider's rows, in configuration order.
    struct ProviderSection: Identifiable, Equatable {
        let id: ProviderID
        let displayName: String
        let credentialDocumentNames: [String]
        let rows: [RootRow]
    }

    private enum Mutation: Sendable {
        case add(providerID: ProviderID, path: String)
        case relabel(id: ProfileRootID, label: String)
        case setEnabled(id: ProfileRootID, isEnabled: Bool)
        case remove(id: ProfileRootID)
    }

    private(set) var sections: [ProviderSection] = []
    private(set) var errorMessage: String?

    @ObservationIgnored private let store: any ProfileRootStore
    @ObservationIgnored private let registry: ProviderRegistry
    @ObservationIgnored private let fileSystem: any ProviderFileSystem
    @ObservationIgnored private let reveal: @MainActor (URL) -> Void
    @ObservationIgnored private let rediscover: @MainActor () async -> Void

    /// The collection storage last accepted. Never replaced by a candidate that failed to save.
    @ObservationIgnored private var persisted: ProfileRootCollection?
    /// How many mutations have settled. A read that began at an older count is an older collection.
    @ObservationIgnored private var settledMutations = 0
    @ObservationIgnored private var mutations: Task<Void, Never>?
    @ObservationIgnored private var rediscoveries: Task<Void, Never>?

    init(
        store: any ProfileRootStore,
        registry: ProviderRegistry,
        fileSystem: any ProviderFileSystem,
        reveal: @escaping @MainActor (URL) -> Void,
        rediscover: @escaping @MainActor () async -> Void
    ) {
        self.store = store
        self.registry = registry
        self.fileSystem = fileSystem
        self.reveal = reveal
        self.rediscover = rediscover
    }

    /// The editor the Settings window runs, bound to the boundaries the coordinator already holds.
    static func live(model: AppModel) -> ProfileSettingsModel {
        ProfileSettingsModel(
            store: model.profileRoots,
            registry: model.registry,
            fileSystem: model.fileSystem,
            reveal: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
            rediscover: { [weak model] in await model?.refreshNow() }
        )
    }

    // MARK: - Reading

    /// Reads storage and rebuilds the rows. A failure leaves the rows that are already on screen.
    ///
    /// The read is stamped with the mutations that had settled when it began. One that settles
    /// while the read is in flight makes that read the older of the two collections, and adopting
    /// it would put the rows back to before the edit and hand the next mutation a collection to
    /// persist the rollback from. A read that comes back stamped stale is dropped instead.
    func load() async {
        let generation = settledMutations
        let outcome: Result<ProfileRootCollection, ProfileRootStoreError>
        do {
            outcome = .success(try await store.load())
        } catch {
            outcome = .failure(error)
        }
        guard settledMutations == generation else { return }
        switch outcome {
        case .success(let collection):
            persisted = collection
            errorMessage = nil
        case .failure(let error):
            errorMessage = Self.message(for: error)
        }
        rebuildSections()
    }

    func dismissError() {
        errorMessage = nil
    }

    // MARK: - Mutating

    /// Records a folder the user picked as a new root for `providerID`.
    ///
    /// The label is left empty on purpose: the collection fills it in from the folder's own name,
    /// and the user renames it from the row.
    func addRoot(providerID: ProviderID, folder: URL) async {
        await perform(.add(providerID: providerID, path: Self.selectedPath(of: folder)))
    }

    func rename(_ id: ProfileRootID, to label: String) async {
        await perform(.relabel(id: id, label: label))
    }

    func setEnabled(_ isEnabled: Bool, for id: ProfileRootID) async {
        await perform(.setEnabled(id: id, isEnabled: isEnabled))
    }

    func removeRoot(_ id: ProfileRootID) async {
        await perform(.remove(id: id))
    }

    /// Reports a folder the file importer could not hand over. Nothing is stored.
    func reportFolderSelectionFailure(_ error: any Error) {
        errorMessage = error.localizedDescription
    }

    /// Shows a configured root in Finder. The action is injected, so nothing here opens Finder.
    func revealInFinder(_ id: ProfileRootID) {
        guard let profile = persisted?.profiles.first(where: { $0.id == id }) else { return }
        reveal(Self.directoryURL(for: profile))
    }

    /// Waits for every queued mutation and for the rediscovery each successful one asked for.
    ///
    /// The editor never awaits this. A mutation persists and returns, and the refresh it requests
    /// runs beside the next edit rather than in front of it — otherwise a second toggle would sit
    /// behind a whole network wave. This exists for a caller that needs the sequence finished.
    func quiesce() async {
        _ = await mutations?.value
        _ = await rediscoveries?.value
    }

    // MARK: - Serialization

    /// Queues one mutation behind the last one.
    ///
    /// Chaining rather than racing: two toggles a moment apart would otherwise both start from the
    /// same collection and the second would erase the first. The queued work runs in an
    /// unstructured task, so a cancelled caller cannot abandon a mutation part-way through it.
    ///
    /// The queued work holds this model rather than a weak reference to it: a save that has been
    /// asked for has to finish even if the Settings window closes while it is in flight, and the
    /// task ends the moment it does.
    private func perform(_ mutation: Mutation) async {
        let previous = mutations
        let task = Task { @MainActor in
            _ = await previous?.value
            await self.commit(mutation)
        }
        mutations = task
        await task.value
    }

    private func commit(_ mutation: Mutation) async {
        // Every path below settles state a load already in flight cannot have read — the applied
        // collection, the refusal, or the save failure — so the stamp moves whichever one is taken.
        defer { settledMutations += 1 }
        guard let current = persisted else {
            errorMessage = "Provider folders have not finished loading yet."
            return
        }
        let candidate: ProfileRootCollection
        do {
            candidate = try Self.applying(mutation, to: current)
        } catch {
            errorMessage = message(for: error)
            return
        }
        do {
            try await store.save(candidate)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }
        persisted = candidate
        errorMessage = nil
        rebuildSections()
        requestRediscovery()
    }

    private func requestRediscovery() {
        let previous = rediscoveries
        rediscoveries = Task { @MainActor in
            _ = await previous?.value
            await self.rediscover()
        }
    }

    private static func applying(
        _ mutation: Mutation,
        to collection: ProfileRootCollection
    ) throws(ProfileRootValidationError) -> ProfileRootCollection {
        var updated = collection
        switch mutation {
        case .add(let providerID, let path):
            try updated.add(providerID: providerID, label: "", configurationDirectoryPath: path)
        case .relabel(let id, let label):
            guard let profile = collection.profiles.first(where: { $0.id == id }) else {
                throw .profileNotFound(id)
            }
            try updated.edit(
                id: id,
                label: label,
                configurationDirectoryPath: profile.configurationDirectoryPath,
                isEnabled: profile.isEnabled
            )
        case .setEnabled(let id, let isEnabled):
            try updated.setEnabled(isEnabled, for: id)
        case .remove(let id):
            try updated.remove(id: id)
        }
        return updated
    }

    // MARK: - Rows

    private func rebuildSections() {
        let profiles = persisted?.profiles ?? []
        var built: [ProviderSection] = []
        var covered: Set<ProviderID> = []
        for provider in registry.providers {
            covered.insert(provider.providerID)
            built.append(
                section(id: provider.providerID, displayName: provider.displayName, in: profiles)
            )
        }
        // A root whose provider is not registered still has to be visible: it is the user's, and a
        // section it never appears in is a root they cannot find, edit, or delete.
        for profile in profiles where !covered.contains(profile.providerID) {
            covered.insert(profile.providerID)
            let id = profile.providerID
            built.append(section(id: id, displayName: id.rawValue, in: profiles))
        }
        sections = built
    }

    private func section(
        id: ProviderID,
        displayName: String,
        in profiles: [ProfileRoot]
    ) -> ProviderSection {
        // A disabled root is checked the same way as one that is not, because the answer describes
        // the folder rather than the schedule.
        var rows: [RootRow] = []
        for profile in profiles where profile.providerID == id {
            rows.append(
                RootRow(
                    profile: profile,
                    hasCredentialDocument: ProviderCredentialDocuments.exists(
                        below: profile,
                        using: fileSystem
                    )
                )
            )
        }
        return ProviderSection(
            id: id,
            displayName: displayName,
            credentialDocumentNames: ProviderCredentialDocuments.names(for: id),
            rows: rows
        )
    }

    static func directoryURL(for profile: ProfileRoot) -> URL {
        URL(filePath: profile.configurationDirectoryPath, directoryHint: .isDirectory)
    }

    /// The absolute path of a folder the user picked. The collection normalizes it from here.
    ///
    /// The security-scoped call is balanced only when it succeeded. It returns false for a URL that
    /// carries no scope, which is every URL in this unsandboxed app, and the path is read either
    /// way — reading a path is not an access. Nothing inside the folder is opened here.
    static func selectedPath(of folder: URL) -> String {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        return folder.standardizedFileURL.path(percentEncoded: false)
    }

    // MARK: - Messages

    private func message(for error: ProfileRootValidationError) -> String {
        switch error {
        case .configurationDirectoryMustBeAbsolute:
            "Choose a folder by its full path."
        case .duplicateConfigurationDirectory(let providerID, let path):
            "\(displayName(for: providerID)) already has a folder at \(path)."
        case .duplicateID, .profileNotFound, .destinationIndexOutOfBounds:
            error.description
        }
    }

    private static func message(for error: ProfileRootStoreError) -> String {
        switch error {
        case .corruptPayload:
            "Saved provider folders could not be read."
        case .unsupportedSchemaVersion(let version):
            "Saved provider folders use an unsupported format (version \(version))."
        case .storageUnavailable:
            "Provider folders could not be saved to preferences."
        case .invalidDefaultRoots(let error):
            error.description
        }
    }

    private func displayName(for providerID: ProviderID) -> String {
        registry.provider(for: providerID)?.displayName ?? providerID.rawValue
    }
}
