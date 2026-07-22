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
                GeneralSettings()
            }
            Tab("Providers", systemImage: "folder") {
                ProviderRootsSettings(settings: settings)
            }
        }
        .frame(width: 620, height: 520)
    }
}

private struct GeneralSettings: View {
    @AppStorage(LiquidGlassStyle.storageKey)
    private var liquidity = LiquidGlassStyle.defaultIntensity

    var body: some View {
        Form {
            LabeledContent("Version", value: UsageKitInfo.version)
            Section {
                Slider(value: $liquidity, in: 0...1) {
                    Text("Liquidity")
                } minimumValueLabel: {
                    Text("Flat")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Liquid")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityValue(liquidity.formatted(.percent.precision(.fractionLength(0))))
            } header: {
                Text("Appearance")
            } footer: {
                Text(
                    "Flat keeps the standard popover. Sliding right fades the popover's "
                        + "backdrop until the desktop shows through; past the midpoint the "
                        + "cards float as Liquid Glass and melt together at full liquid."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
