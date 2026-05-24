import SwiftUI

struct MainWindow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        DetailView()
            .navigationTitle("Claude Desktop Switch")
            .frame(minWidth: 650, minHeight: 450)
    }
}
