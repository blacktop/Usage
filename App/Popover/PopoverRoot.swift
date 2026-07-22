import AppKit
import SwiftUI
import UsageKit

struct PopoverRoot: View {
    let lifecycle: MenuLifecycleRecorder
    let model: AppModel

    @AppStorage(LiquidGlassStyle.storageKey)
    private var liquidity = LiquidGlassStyle.defaultIntensity

    private var store: UsageStore { model.store }
    private var sections: [PopoverAccountSection] {
        PopoverAccountSection.sections(
            accounts: store.accounts,
            profiles: model.configuredProfiles,
            registry: model.registry
        )
    }

    var body: some View {
        let glass = LiquidGlassStyle(intensity: liquidity)
        let sections = sections
        return VStack(alignment: .leading, spacing: 12) {
            PopoverHeader(isRefreshing: store.isRefreshing, glass: glass, refresh: refresh)
            if !glass.usesGlassIslands {
                Divider()
            }
            PopoverAccountList(sections: sections, glass: glass, onRetry: retry)
            DiscoveryFailureList(failures: store.discoveryFailures)

            if !glass.usesGlassIslands {
                Divider()
            }

            PopoverFooter(glass: glass, quit: quit)
        }
        .padding(14)
        .frame(width: PopoverOverviewLayout.width)
        // Once liquidity strips the window's stock glass frame, this rounded material is the
        // whole backdrop; it fades with the slider until only the glass islands remain over the
        // desktop. At Flat the stock frame is intact and no custom backdrop is drawn.
        .background {
            if glass.usesCustomWindowBackdrop {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .opacity(glass.backdropAlpha)
            }
        }
        .background(PopoverWindowBackdrop(alpha: glass.backdropAlpha))
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
    let glass: LiquidGlassStyle
    let refresh: () -> Void

    var body: some View {
        if glass.usesGlassIslands {
            row
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
        } else {
            row
        }
    }

    private var row: some View {
        HStack {
            Text("Usage")
                .font(.headline)
            Spacer()
            refreshButton
                .controlSize(.small)
                .disabled(isRefreshing)
                .accessibilityLabel("Refresh")
                .help("Refresh usage")
        }
    }

    @ViewBuilder
    private var refreshButton: some View {
        let button = Button(action: refresh) {
            Image(systemName: "arrow.clockwise")
                .frame(width: 16, height: 16)
        }
        if glass.usesGlassControls {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.borderless)
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

    let glass: LiquidGlassStyle
    let quit: () -> Void

    var body: some View {
        if glass.usesGlassIslands {
            row
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .glassEffect(.regular, in: .capsule)
        } else {
            row
        }
    }

    private var row: some View {
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
