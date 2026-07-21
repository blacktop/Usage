import AppKit
import SwiftUI
import UsageKit

struct PopoverRoot: View {
    let lifecycle: MenuLifecycleRecorder
    let model: AppModel

    private var store: UsageStore { model.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if store.accounts.isEmpty {
                Text("No accounts discovered yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.accounts) { state in
                    AccountCard(state: state) {
                        Task { await model.refreshNow() }
                    }
                }
            }
            ForEach(store.discoveryFailures.sorted { $0.key.rawValue < $1.key.rawValue }, id: \.key)
            { provider, error in
                Label(
                    "\(provider.rawValue): \(error.message)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            Divider()

            footer
        }
        .padding(16)
        .frame(width: 320)
        // Instrumentation only. These counts are what a human reads out of the unified log to fill
        // in the results table in docs/menu-bar-lifecycle.md. Nothing here feeds scheduling: until
        // that table shows appearances and disappearances pairing, the appearance signal is not
        // trusted enough to pick a refresh cadence.
        .onAppear { lifecycle.recordAppear() }
        .onDisappear { lifecycle.recordDisappear() }
    }

    private var header: some View {
        HStack {
            Text("Usage")
                .font(.headline)
            Spacer()
            Button {
                Task { await model.refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .accessibilityLabel("Refresh")
        }
    }

    private var footer: some View {
        HStack {
            SettingsLink {
                Text("Settings…")
            }
            Spacer()
            Text(
                "appear \(lifecycle.appearances) · disappear \(lifecycle.disappearances) · "
                    + (lifecycle.isBalanced ? "balanced" : "unbalanced")
            )
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
