import SwiftUI

enum Tab: String, CaseIterable {
    case status = "Status"
    case providers = "Desktop Providers"
    case settings = "Settings"
    case logs = "Logs"
}

struct DetailView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedTab: Tab = .status

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            // Tab content
            switch selectedTab {
            case .status:
                ConnectionStatusView()
                    .environmentObject(appState)
            case .logs:
                LogsView()
                    .environmentObject(appState)
            case .providers:
                ProviderListView()
                    .environmentObject(appState)
            case .settings:
                SettingsView()
                    .environmentObject(appState)
            }
        }
    }
}

struct LogsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent Requests")
                    .font(.headline)
                Spacer()
                Button {
                    appState.proxyServer.clearRequestLogs()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear request log")
                .disabled(appState.requestLogs.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if appState.requestLogs.isEmpty {
                VStack {
                    Spacer()
                    Text("No requests yet")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(appState.requestLogs) { log in
                            requestLogRow(log)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func requestLogRow(_ log: ProxyRequestLog) -> some View {
        HStack(spacing: 10) {
            Text(log.timestamp, style: .time)
                .frame(width: 74, alignment: .leading)
                .foregroundColor(.secondary)

            Text(log.method)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 48, alignment: .leading)

            Text("\(log.status)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(statusColor(log.status))
                .frame(width: 40, alignment: .leading)

            Text(log.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(log.providerName ?? "-")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 120, alignment: .trailing)

            Text("\(Int(log.duration * 1000)) ms")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.caption)
        .help(log.error ?? "\(log.method) \(log.path)")
        .padding(.vertical, 7)
    }

    private func statusColor(_ status: Int) -> Color {
        switch status {
        case 200..<300: return .green
        case 400..<500: return .orange
        case 500...: return .red
        default: return .secondary
        }
    }
}
