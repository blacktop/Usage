import SwiftUI
import UsageKit

struct SettingsRoot: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    LabeledContent("Version", value: UsageKitInfo.version)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 460, height: 260)
    }
}
