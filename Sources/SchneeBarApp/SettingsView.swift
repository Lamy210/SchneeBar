import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("SchneeBar") {
                LabeledContent("Status", value: "Bootstrap")
                LabeledContent("Platform", value: "macOS 15+")
            }

            Section("Developer Activity") {
                Text("GitHub connection and provider settings will live here without leaking provider-specific state into the UI layer.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 320)
        .padding()
    }
}
