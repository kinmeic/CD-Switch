import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppState.shared.quitRequested ? .terminateNow : .terminateCancel
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if AppState.shared.autoStartProxy {
            DispatchQueue.main.async {
                AppState.shared.startProxy()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if AppState.shared.proxyServer.running {
            AppState.shared.stopProxy()
        }
    }
}

@main
struct ClaudeSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(appState)
        } label: {
            Image(appState.proxyRunning ? "MenuBarIconActive" : "MenuBarIcon")
                .renderingMode(.original)
                .id(appState.proxyRunning)
                .accessibilityLabel(appState.proxyRunning ? "ClaudeSwitch proxy running" : "ClaudeSwitch proxy stopped")
        }

        WindowGroup("Claude Desktop Switch", id: "main") {
            MainWindow()
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 450)
        }
        .defaultSize(width: 700, height: 500)
    }
}
