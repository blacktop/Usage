import SwiftUI
import UniformTypeIdentifiers
import UsageKit

/// The provider-folder editor: one section per provider, one row per configured folder.
///
/// Sections come from the model already grouped and already ordered, so a row's position is the
/// position it has in storage and its identity is its own `ProfileRootID`. Adding a fiftieth folder
/// appends a row; it does not renumber, regroup, or reshuffle the forty-nine above it.
struct ProviderRootsSettings: View {
    let settings: ProfileSettingsModel

    @State private var isImportingFolder = false
    @State private var importProvider: ProviderID?

    var body: some View {
        Form {
            if let message = settings.errorMessage {
                Section { errorBanner(message) }
            }
            ForEach(settings.sections) { section in
                Section {
                    if section.rows.isEmpty {
                        emptyState(section)
                    } else {
                        ForEach(section.rows) { row in
                            ProfileRootRow(row: row, settings: settings)
                        }
                    }
                } header: {
                    header(section)
                } footer: {
                    if let guidance = ProviderCredentialDocuments.guidance(for: section.id) {
                        Text(guidance)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(
            isPresented: $isImportingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: adoptSelectedFolder
        )
        .task { await settings.load() }
    }

    private func header(_ section: ProfileSettingsModel.ProviderSection) -> some View {
        HStack {
            Text(section.displayName)
            Spacer()
            Button("Add Config Folder…") {
                importProvider = section.id
                isImportingFolder = true
            }
            .accessibilityLabel("Add a config folder for \(section.displayName)")
        }
    }

    private func emptyState(_ section: ProfileSettingsModel.ProviderSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No folders yet.")
                .foregroundStyle(.secondary)
            Text(
                "Choose Add Config Folder… and pick the directory \(section.displayName) keeps "
                    + "its configuration in."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            if let documents = documentList(section) {
                Text("Usage looks for \(documents) there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Spacer(minLength: 12)
            Button("Dismiss") { settings.dismissError() }
                .buttonStyle(.link)
        }
    }

    private func documentList(_ section: ProfileSettingsModel.ProviderSection) -> String? {
        let names = section.credentialDocumentNames
        guard !names.isEmpty else { return nil }
        return names.formatted(.list(type: .or))
    }

    /// Records the folder the importer returned, for the provider whose button opened it.
    ///
    /// The provider is read back out of view state rather than captured by the sheet, so a second
    /// section's button cannot land its folder in the first section's list.
    private func adoptSelectedFolder(_ result: Result<[URL], any Error>) {
        let providerID = importProvider
        importProvider = nil
        guard let providerID else { return }
        switch result {
        case .success(let folders):
            guard let folder = folders.first else { return }
            Task { await settings.addRoot(providerID: providerID, folder: folder) }
        case .failure(let error):
            settings.reportFolderSelectionFailure(error)
        }
    }
}
