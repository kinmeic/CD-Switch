import SwiftUI

struct ConnectionStatusView: View {
    @EnvironmentObject private var appState: AppState

    private var serverAddress: String {
        "http://127.0.0.1:\(appState.proxyPort)/claude-desktop"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
            // Status indicator
            VStack(spacing: 8) {
                Image(systemName: appState.proxyRunning ? "network" : "network.slash")
                    .font(.system(size: 48))
                    .foregroundColor(appState.proxyRunning ? .green : .secondary)

                Text(appState.proxyRunning ? "Proxy Running" : "Proxy Stopped")
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .padding(.top, 20)

            // Proxy Server address
            GroupBox("Proxy Server") {
                HStack {
                    Text(serverAddress)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copyToClipboard(serverAddress)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy address")
                }
                .padding(4)
            }
            .padding(.horizontal, 20)

            // Gateway Token
            GroupBox("Gateway Token") {
                HStack {
                    Text(appState.gatewayToken)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        copyToClipboard(appState.gatewayToken)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy token")
                }
                .padding(4)
            }
            .padding(.horizontal, 20)

            // Active provider info
            if let provider = appState.activeProvider {
                GroupBox("Active Provider") {
                    HStack {
                        Text(provider.name)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(4)
                }
                .padding(.horizontal, 20)
            } else {
                Text("No provider selected")
                    .foregroundColor(.secondary)
            }

            // Action buttons
            HStack(spacing: 12) {
                if appState.proxyRunning {
                    Button("Stop Proxy") {
                        appState.stopProxy()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Start Proxy") {
                        appState.startProxy()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.activeProvider == nil)
                }
            }

            // Proxy errors
            if let error = appState.proxyServer.lastError {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
            }

            // Version
            Text("v1.0.0")
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
