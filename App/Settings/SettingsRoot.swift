import SwiftUI
import UsageKit

/// The Settings window: the build it is, and the folders it reads.
///
/// The editor's model is created once here and owned by `@State`, so it outlives every re-render of
/// this view and every switch between the two tabs.
struct SettingsRoot: View {
    @State private var settings: ProfileSettingsModel

    init(model: AppModel) {
        _settings = State(initialValue: ProfileSettingsModel.live(model: model))
    }

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    LabeledContent("Version", value: UsageKitInfo.version)
                }
                .formStyle(.grouped)
            }
            Tab("Providers", systemImage: "folder") {
                ProviderRootsSettings(settings: settings)
            }
        }
        .frame(width: 620, height: 520)
    }
}
