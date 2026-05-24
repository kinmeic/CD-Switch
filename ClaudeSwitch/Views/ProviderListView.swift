import SwiftUI

struct ProviderListView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedId: UUID?
    @State private var showAddSheet = false

    var body: some View {
        HSplitView {
            // Provider list — narrow sidebar
            VStack(spacing: 0) {
                List(selection: $selectedId) {
                    ForEach(appState.providers) { provider in
                        ProviderRow(provider: provider, isActive: provider.id == appState.activeProviderId)
                            .tag(provider.id)
                            .contextMenu {
                                Button("Duplicate") {
                                    _ = appState.duplicateProvider(provider)
                                }
                                Button("Delete") {
                                    appState.removeProvider(provider)
                                    if selectedId == provider.id { selectedId = nil }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)

                // Bottom toolbar
                HStack {
                    Button { showAddSheet = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                    Spacer()
                    if let selectedId, let provider = appState.providers.first(where: { $0.id == selectedId }) {
                        Button { appState.setActive(provider) } label: { Image(systemName: "checkmark.circle") }
                            .buttonStyle(.borderless)
                            .help("Set as active provider")
                        Button { appState.removeProvider(provider); self.selectedId = nil } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(8)
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 200)

            // Detail editor
            if let selectedId, let provider = appState.providers.first(where: { $0.id == selectedId }) {
                ProviderEditor(provider: provider)
                    .environmentObject(appState)
                    .id(provider.id)
                    .frame(maxWidth: .infinity)
            } else {
                VStack { Spacer(); Text("Select a provider").foregroundColor(.secondary); Spacer() }
                    .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddProviderSheet(isPresented: $showAddSheet).environmentObject(appState)
        }
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: Provider
    let isActive: Bool

    var body: some View {
        HStack {
            Text(provider.name)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
            Spacer()
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Provider Editor

struct ProviderEditor: View {
    @EnvironmentObject private var appState: AppState
    let provider: Provider

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var modelRoutes: [ModelRoute] = []
    @State private var hasChanges = false
    @State private var isLoaded = false
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // General fields
                    VStack(alignment: .leading, spacing: 8) {
                        Text("General")
                            .font(.headline)
                            .padding(.horizontal, 20)

                        VStack(spacing: 0) {
                            fieldRow(label: "Name") {
                                TextField("", text: $name)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }
                            Divider().padding(.horizontal, 8)
                            fieldRow(label: "Base URL") {
                                TextField("", text: $baseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }
                            Divider().padding(.horizontal, 8)
                            fieldRow(label: "API Key") {
                                SecureField("", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)
                        .padding(.horizontal, 20)
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 8)

                    // Model Mapping
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model Mapping")
                            .font(.headline)
                            .padding(.horizontal, 20)

                        Text("Model ID is what Claude Desktop sees. Display Name appears in Claude Desktop, and Upstream Model is sent to the provider.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 20)

                        ModelRoutesTable(modelRoutes: $modelRoutes, baseURL: baseURL, apiKey: apiKey)
                            .padding(.horizontal, 20)
                    }
                    .padding(.vertical, 8)
                }
            }

            // Bottom bar: Test Connection + Save (outside scroll)
            HStack {
                Button {
                    testing = true
                    testResult = nil
                    let tempProvider = Provider(
                        id: provider.id, name: name, baseURL: baseURL,
                        apiKey: apiKey, modelRoutes: modelRoutes
                    )
                    appState.testConnection(provider: tempProvider) { result in
                        testing = false
                        switch result {
                        case .success(let msg): testResult = msg
                        case .failure(let err): testResult = "Failed: \(err.localizedDescription)"
                        }
                    }
                } label: {
                    HStack {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test Connection")
                    }
                }
                .disabled(testing || apiKey.isEmpty)

                if let testResult {
                    Text(testResult)
                        .font(.caption)
                        .foregroundColor(testResult.contains("successful") ? .green : .red)
                }

                Spacer()

                if hasChanges {
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            load(provider)
        }
        .onChange(of: provider.id) { _ in load(provider) }
        .onChange(of: name) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: baseURL) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: apiKey) { _ in if isLoaded { hasChanges = true } }
        .onChange(of: modelRoutes) { _ in if isLoaded { hasChanges = true } }
    }

    private func load(_ provider: Provider) {
        isLoaded = false
        name = provider.name
        baseURL = provider.baseURL
        apiKey = provider.apiKey
        modelRoutes = provider.modelRoutes
        testResult = nil
        testing = false
        hasChanges = false
        DispatchQueue.main.async { isLoaded = true }
    }

    private func save() {
        var updated = provider
        updated.name = name
        updated.baseURL = baseURL
        updated.apiKey = apiKey
        updated.modelRoutes = modelRoutes.map(\.normalized)
        appState.updateProvider(updated)
        modelRoutes = updated.modelRoutes
        hasChanges = false
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 70, alignment: .trailing)
                .font(.body)
            content()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

// MARK: - Model Routes Table

struct ModelRoutesTable: View {
    @EnvironmentObject private var appState: AppState
    @Binding var modelRoutes: [ModelRoute]
    let baseURL: String
    let apiKey: String
    @State private var discovering = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Model ID")
                    .frame(width: 180, alignment: .leading)
                Text("Display Name")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Upstream Model")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("1M")
                    .frame(width: 36, alignment: .center)
                Color.clear.frame(width: 24)
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            // Rows
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($modelRoutes) { $route in
                        routeRow($route)
                        if route.id != modelRoutes.last?.id {
                            Divider().padding(.horizontal, 8)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            Divider()

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    discoverModels()
                } label: {
                    HStack(spacing: 4) {
                        if discovering { ProgressView().controlSize(.small) }
                        Image(systemName: "square.and.arrow.down")
                        Text("Get Model List")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(discovering || apiKey.isEmpty)

                Button {
                    let defaultModelId = ModelRoute.normalizedClaudeModelIds(appState.claudeModelIds)[0]
                    modelRoutes.append(ModelRoute(routeId: defaultModelId, upstreamModel: "", labelOverride: nil, supports1m: true))
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Add Model")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }
            .padding(8)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(6)
    }

    @ViewBuilder
    private func routeRow(_ route: Binding<ModelRoute>) -> some View {
        HStack(spacing: 12) {
            Picker("", selection: route.routeId) {
                ForEach(availableModelIds(for: route.wrappedValue.routeId), id: \.self) { modelId in
                    Text(modelId).tag(modelId)
                }
            }
            .frame(width: 180)
            .labelsHidden()

            TextField("Display Name", text: Binding(
                get: { route.wrappedValue.labelOverride ?? "" },
                set: { route.wrappedValue.labelOverride = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)

            TextField("Provider model ID", text: route.upstreamModel)
                .textFieldStyle(.roundedBorder)

            Toggle("", isOn: route.supports1m)
                .toggleStyle(.checkbox)
                .frame(width: 36, alignment: .center)

            Button { modelRoutes.removeAll { $0.id == route.wrappedValue.id } } label: {
                Image(systemName: "trash")
                    .foregroundColor(.red.opacity(0.7))
            }
            .buttonStyle(.borderless)
            .frame(width: 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func availableModelIds(for currentValue: String) -> [String] {
        var ids = ModelRoute.normalizedClaudeModelIds(appState.claudeModelIds)
        let current = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !ids.contains(current) {
            ids.append(current)
        }
        return ids
    }

    private func discoverModels() {
        guard let url = URL(string: baseURL + "/v1/models") else { return }
        discovering = true

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { DispatchQueue.main.async { discovering = false } }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else { return }
            let modelIds = models.compactMap { $0["id"] as? String }
            DispatchQueue.main.async {
                for i in 0..<modelRoutes.count where modelRoutes[i].upstreamModel.isEmpty {
                    if let first = modelIds.first { modelRoutes[i].upstreamModel = first }
                }
            }
        }.resume()
    }
}

// MARK: - Add Provider Sheet

struct AddProviderSheet: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var baseURL = "https://api.anthropic.com"
    @State private var apiKey = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Add Provider").font(.headline)
            Form {
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Base URL", text: $baseURL).textFieldStyle(.roundedBorder)
                SecureField("API Key", text: $apiKey).textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") {
                    appState.addProvider(Provider(name: name.isEmpty ? "New Provider" : name, baseURL: baseURL, apiKey: apiKey))
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty && baseURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
