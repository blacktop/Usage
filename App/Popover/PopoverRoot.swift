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
        VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(isRefreshing: store.isRefreshing, refresh: refresh)
            PopoverAccountList(sections: sections, onRetry: refresh)
            DiscoveryFailureList(failures: store.discoveryFailures)

            Divider()

            PopoverFooter(lifecycle: lifecycle, quit: quit)
        }
        .padding(16)
        .frame(width: 360)
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
            }
            .buttonStyle(.glass)
            .disabled(isRefreshing)
            .accessibilityLabel("Refresh")
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
    let lifecycle: MenuLifecycleRecorder
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(
                "appear \(lifecycle.appearances) · disappear \(lifecycle.disappearances) · "
                    + (lifecycle.isBalanced ? "balanced" : "unbalanced")
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)

            GlassEffectContainer(spacing: 8) {
                HStack {
                    SettingsLink {
                        Text("Settings…")
                    }
                    .buttonStyle(.glass)
                    Spacer()
                    Button("Quit", action: quit)
                        .buttonStyle(.glass)
                        .keyboardShortcut("q")
                }
            }
        }
    }
}
