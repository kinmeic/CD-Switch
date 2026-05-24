import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Proxy") {
                HStack {
                    Text("Port:")
                    Spacer()
                    TextField("", value: $appState.proxyPort, format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }

                Toggle("Auto-start proxy on launch", isOn: $appState.autoStartProxy)
            }

            Section("Claude Desktop") {
                TextField("Config Directory", text: $appState.claudeDesktopPath)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Gateway Token") {
                HStack {
                    Text(appState.gatewayToken)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Regenerate") {
                        appState.gatewayToken = "cs-\(UUID().uuidString.lowercased())"
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
