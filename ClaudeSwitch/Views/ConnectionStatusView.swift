import SwiftUI

struct ConnectionStatusView: View {
    @EnvironmentObject private var appState: AppState

    private var serverAddress: String {
        "http://127.0.0.1:\(appState.proxyPort)/claude-desktop"
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    /// 当存在漂移时返回一条提示；无漂移返回 nil。仅在已配置 profile 时判定，避免误报。
    private var claudeDesktopDriftWarning: String? {
        let status = appState.claudeDesktopStatus
        guard status.configured else { return nil }

        if status.baseURLDrift {
            return "Claude Desktop profile 的网关地址与当前端口不匹配，可能被其他工具覆盖。重新启动代理以修复。"
        }
        if status.staleRawModels {
            return "Claude Desktop profile 含有非官方模型名，可能触发 fail-all 导致模型菜单为空。重新启动代理以修复。"
        }
        if status.missingRouteMappings {
            return "当前 provider 没有可用的模型路由，请先在 provider 编辑中配置路由。"
        }
        return nil
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

            // Drift warnings
            if let drift = claudeDesktopDriftWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text(drift)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 20)
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
            Text("v\(appVersion)")
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
