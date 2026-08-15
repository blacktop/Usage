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
    @State private var isEditingSetupToken = false
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
            Text(
                "Usage stops reading \(profile.configurationDirectoryPath). The folder is kept, "
                    + "and any setup token Usage saved for it is removed."
            )
        }
        .sheet(isPresented: $isEditingSetupToken) {
            ClaudeSetupTokenSheet(
                row: row,
                settings: settings,
                isPresented: $isEditingSetupToken
            )
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

    private var credentialStatus: some View {
        Label(
            ProviderCredentialDocuments.status(
                providerID: profile.providerID,
                hasCredentialDocument: row.hasCredentialDocument,
                hasSetupToken: row.hasSetupToken
            ),
            systemImage: row.hasCredentialDocument || row.hasSetupToken
                ? "checkmark.circle"
                : "key"
        )
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// Both buttons name the folder they act on. Icon-only rendering leaves a screen reader with
    /// nothing but the label, and "Remove" fifty times over is fifty rows a user cannot tell apart.
    private var actions: some View {
        HStack(spacing: 4) {
            if profile.providerID == ClaudeProvider.id {
                Button {
                    isEditingSetupToken = true
                } label: {
                    Label(
                        row.hasSetupToken ? "Replace setup token" : "Add setup token",
                        systemImage: "key.horizontal"
                    )
                }
                .accessibilityLabel(
                    row.hasSetupToken
                        ? "Replace the Claude setup token for “\(profile.label)”"
                        : "Add a Claude setup token for “\(profile.label)”"
                )
                .help(row.hasSetupToken ? "Replace setup token" : "Add setup token")
            }

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

/// Explicit import for the long-lived, inference-only token printed by Claude Code.
///
/// The draft belongs to this sheet and is cleared before dismissal. The settings model hands it
/// straight to the Keychain boundary and never publishes or retains it.
private struct ClaudeSetupTokenSheet: View {
    let row: ProfileSettingsModel.RootRow
    let settings: ProfileSettingsModel
    @Binding var isPresented: Bool

    @State private var token = ""
    @FocusState private var isTokenFocused: Bool

    private var profile: ProfileRoot { row.profile }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(row.hasSetupToken ? "Replace Claude Setup Token" : "Add Claude Setup Token")
                .font(.title2.weight(.semibold))

            Text(
                "Run this in Terminal, approve the browser flow for “\(profile.label)”, then "
                    + "paste the token Claude prints:"
            )
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)

            SecureField("sk-ant-oat01-…", text: $token)
                .textFieldStyle(.roundedBorder)
                .focused($isTokenFocused)
                .onSubmit(save)

            if let errorMessage = settings.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(
                "Usage stores it in its own Keychain item and uses it only when neither "
                    + "credentials.json nor Claude Code’s root-specific Keychain item is usable. "
                    + "Each refresh makes a one-output-token inference probe; this reports the "
                    + "5-hour and 7-day windows, not model-specific or extra-usage limits."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                if row.hasSetupToken {
                    Button("Remove Token", role: .destructive, action: remove)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear { isTokenFocused = true }
    }

    private var command: String {
        "claude setup-token"
    }

    private func save() {
        guard settings.saveClaudeSetupToken(token, for: row.id) else { return }
        dismiss()
    }

    private func remove() {
        guard settings.removeClaudeSetupToken(for: row.id) else { return }
        dismiss()
    }

    private func dismiss() {
        token = ""
        isPresented = false
    }
}
