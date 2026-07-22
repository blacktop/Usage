import AppKit
import SwiftUI
import UsageKit

struct PopoverRoot: View {
    let lifecycle: MenuLifecycleRecorder
    let model: AppModel

    private var store: UsageStore { model.store }
    private var sections: [PopoverAccountSection] {
        PopoverAccountSection.sections(
            accounts: store.accounts,
            profiles: model.configuredProfiles,
            registry: model.registry
        )
    }

    var body: some View {
        let sections = sections
        return VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(isRefreshing: store.isRefreshing, refresh: refresh)
            Divider()
            PopoverAccountList(sections: sections, onRetry: retry)
            DiscoveryFailureList(failures: store.discoveryFailures)

            Divider()

            PopoverFooter(quit: quit)
        }
        .padding(14)
        .frame(width: PopoverOverviewLayout.width)
        // Instrumentation only. These counts are what a human reads out of the unified log to fill
        // in the results table in docs/menu-bar-lifecycle.md. Nothing here feeds scheduling: until
        // that table shows appearances and disappearances pairing, the appearance signal is not
        // trusted enough to pick a refresh cadence.
        .onAppear { lifecycle.recordAppear() }
        .onDisappear { lifecycle.recordDisappear() }
    }

    private func refresh() {
        Task { await model.refreshNow() }
    }

    private func retry(_ key: AccountKey, requiresCredentialApproval: Bool) {
        Task {
            if requiresCredentialApproval {
                NSApplication.shared.activate(ignoringOtherApps: true)
                await model.approveCredentialAccess(for: key)
            } else {
                await model.refreshNow()
            }
        }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

private struct PopoverHeader: View {
    let isRefreshing: Bool
    let refresh: () -> Void

    var body: some View {
        HStack {
            Text("Usage")
                .font(.headline)
            Spacer()
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh")
            .help("Refresh usage")
        }
    }
}

private struct DiscoveryFailureList: View {
    let failures: [ProviderID: UsageError]

    var body: some View {
        ForEach(failures.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key) {
            provider, error in
            Label(
                "\(provider.rawValue): \(error.message)",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }
}

private struct PopoverFooter: View {
    @Environment(\.openSettings) private var openSettings

    let quit: () -> Void

    var body: some View {
        HStack {
            Button("Settings…") {
                SettingsWindowPresenter(
                    activate: {
                        NSApplication.shared.activate(ignoringOtherApps: true)
                    },
                    open: {
                        openSettings()
                    }
                ).show()
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit", action: quit)
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
                .help("Quit Usage")
        }
        .font(.caption)
    }
}
