import SwiftUI

struct MenuBarMenu: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) var openWindow

    var body: some View {
        providerMenu
        Divider()
        proxyButton
        Divider()
        Button("Show Window") { showMainWindow() }
        Divider()
        Button("Quit") { appState.requestQuit() }
            .keyboardShortcut("q")
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var providerMenu: some View {
        Menu("Desktop Providers") {
            if appState.providers.isEmpty {
                Text("No Providers")
            } else {
                ForEach(appState.providers) { provider in
                    let isActive = provider.id == appState.activeProviderId
                    Button(isActive ? "✓ \(provider.name)" : provider.name) {
                        selectProvider(provider)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var proxyButton: some View {
        if appState.proxyRunning {
            Button("Stop Proxy") { appState.stopProxy() }
        } else {
            Button("Start Proxy") { appState.startProxy() }
                .disabled(appState.activeProvider == nil)
        }
    }

    // MARK: - Actions

    private func selectProvider(_ provider: Provider) {
        appState.setActive(provider)
    }

    private func showMainWindow() {
        let existing = NSApp.windows.first {
            $0.isVisible && !($0 is NSPanel) &&
            ($0.identifier?.rawValue == "main")
        }
        if let window = existing {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openWindow(id: "main")
        }
    }
}
