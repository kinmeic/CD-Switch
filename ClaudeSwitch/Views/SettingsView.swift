import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newClaudeModelId = ""

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

            Section("Rectifier") {
                Toggle("Enable Rectifier", isOn: $appState.rectifierEnabled)

                Toggle("Thinking Signature Rectification", isOn: $appState.rectifyThinkingSignature)
                    .disabled(!appState.rectifierEnabled)

                Toggle("Thinking Budget Rectification", isOn: $appState.rectifyThinkingBudget)
                    .disabled(!appState.rectifierEnabled)
            }

            Section("Claude Desktop") {
                TextField("Config Directory", text: $appState.claudeDesktopPath)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Claude Model IDs") {
                ForEach(appState.claudeModelIds.indices, id: \.self) { index in
                    HStack {
                        TextField("Model ID", text: Binding(
                            get: {
                                guard appState.claudeModelIds.indices.contains(index) else { return "" }
                                return appState.claudeModelIds[index]
                            },
                            set: { value in
                                guard appState.claudeModelIds.indices.contains(index) else { return }
                                appState.claudeModelIds[index] = value
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button {
                            guard appState.claudeModelIds.indices.contains(index) else { return }
                            appState.claudeModelIds.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                                .foregroundColor(.red.opacity(0.7))
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("New Model ID", text: $newClaudeModelId)
                        .textFieldStyle(.roundedBorder)

                    Button {
                        appState.claudeModelIds.append(newClaudeModelId)
                        newClaudeModelId = ""
                    } label: {
                        Label("Add Model ID", systemImage: "plus")
                    }
                    .disabled(newClaudeModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            Section("Outbound Proxy") {
                HStack {
                    Text("Address:")
                    Spacer()
                    TextField("", text: $appState.outboundProxyURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                }

                if let message = appState.outboundProxyValidationMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Used by CD-Switch outbound requests. Leave empty for direct connection.")
                    Text(verbatim: "Examples: http://127.0.0.1:7890, socks5://127.0.0.1:1080")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(16)
    }
}
