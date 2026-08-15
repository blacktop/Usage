import Foundation
import SwiftUI

@main
struct UsageApp: App {
    @State private var lifecycle = MenuLifecycleRecorder()
    @State private var model: AppModel

    init() {
        // The Keychain gate has to measure this bundle's own identity, and it must not measure a
        // running menu bar app: the probe exits here, before a scene, a model, or a refresh exists.
        if let invocation = KeychainDiagnostic.invocation(from: CommandLine.arguments) {
            KeychainDiagnostic.run(invocation)
            exit(EXIT_SUCCESS)
        }
        if let invocation = ClaudeGateDiagnostic.invocation(from: CommandLine.arguments) {
            ClaudeGateDiagnostic.run(invocation)
        }
        let model = AppModel.live()
        _model = State(initialValue: model)
        // A menu bar app has to refresh whether or not its popover is ever opened, so the first
        // refresh belongs to the scene rather than to a view's appearance.
        Task { await model.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverRoot(lifecycle: lifecycle, model: model)
        } label: {
            MenuBarLabel(
                best: BestProviderUsage.select(
                    accounts: model.store.accounts,
                    registry: model.registry
                )
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsRoot(model: model)
        }
    }
}
