import SwiftUI
import UsageKit

/// One configured folder: whether it is read, what it is called, where it is, and whether the
/// provider's document is there.
///
/// The label field is a draft. It commits when the user submits it or moves focus away, so a
/// half-typed name never reaches storage and never costs a rediscovery.
struct ProfileRootRow: View {
    let row: ProfileSettingsModel.RootRow
    let settings: ProfileSettingsModel

    @State private var draftLabel = ""
    @State private var isConfirmingRemoval = false
    @FocusState private var isEditingLabel: Bool

    private var profile: ProfileRoot { row.profile }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("Read this folder", isOn: enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel("Read the folder “\(profile.label)”")
                .help("Read this folder during a refresh")
            details
            Spacer(minLength: 0)
            actions
        }
        .padding(.vertical, 4)
        .onChange(of: profile.label, initial: true) { _, label in draftLabel = label }
        .onChange(of: isEditingLabel) { _, isEditing in
            if !isEditing {
                commitLabel()
            }
        }
        .confirmationDialog(
            "Remove “\(profile.label)” from Usage?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task { await settings.removeRoot(row.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Usage stops reading \(profile.configurationDirectoryPath). The folder is kept.")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Label", text: $draftLabel)
                .textFieldStyle(.roundedBorder)
                .focused($isEditingLabel)
                .onSubmit { commitLabel() }
                .accessibilityLabel("Label for \(profile.configurationDirectoryPath)")
            Text(profile.configurationDirectoryPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            credentialStatus
        }
    }

    @ViewBuilder private var credentialStatus: some View {
        if row.hasCredentialDocument {
            Label("Sign-in file found", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Label("No sign-in file in this folder", systemImage: "key")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    /// Both buttons name the folder they act on. Icon-only rendering leaves a screen reader with
    /// nothing but the label, and "Remove" fifty times over is fifty rows a user cannot tell apart.
    private var actions: some View {
        HStack(spacing: 4) {
            Button {
                settings.revealInFinder(row.id)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .accessibilityLabel("Reveal “\(profile.label)” in Finder")
            .help("Reveal in Finder")

            Button(role: .destructive) {
                isConfirmingRemoval = true
            } label: {
                Label("Remove", systemImage: "trash")
            }
            .accessibilityLabel("Remove “\(profile.label)” from Usage")
            .help("Remove this folder from Usage")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { profile.isEnabled },
            set: { isEnabled in
                Task { await settings.setEnabled(isEnabled, for: row.id) }
            }
        )
    }

    /// An empty draft is a discarded edit rather than a rename: the collection would fill the label
    /// back in from the folder name, so restoring the field says the same thing without a write.
    private func commitLabel() {
        let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftLabel = profile.label
            return
        }
        guard trimmed != profile.label else { return }
        Task { await settings.rename(row.id, to: trimmed) }
    }
}
