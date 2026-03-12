import SwiftUI

@Observable
final class AppState {
    var providers: [ProviderConfig]
    var selectedProviderType: AIProviderType
    var serverPort: String = "1234"
    var customSystemPrompt: String = "请使用中文回答"
    var isServerRunning: Bool = false
    var serverStatus: String = "Stopped"
    var logs: [String] = []
    var isFetchingModels: Bool = false
    var isTestingConnection: Bool = false
    var lastTestResult: (success: Bool, message: String)? = nil
    var currentModelInUse: String = ""

    private let server = ProxyServer()
    private let configKey = "providerConfigs"
    private let portKey = "serverPort"
    private let selectedProviderKey = "selectedProviderType"
    private let customSystemPromptKey = "customSystemPrompt"

    var selectedProvider: ProviderConfig {
        get {
            providers.first(where: { $0.type == selectedProviderType })
                ?? ProviderConfig(type: selectedProviderType)
        }
        set {
            if let index = providers.firstIndex(where: { $0.type == selectedProviderType }) {
                providers[index] = newValue
                saveProviders()
            }
        }
    }

    init() {
        // Load provider structure from UserDefaults (without API keys)
        if let data = UserDefaults.standard.data(forKey: configKey),
            var configs = try? JSONDecoder().decode([ProviderConfig].self, from: data)
        {
            // Load API keys from Keychain for each provider
            for i in configs.indices {
                let keyKey = "api_key_\(configs[i].type.rawValue)"
                if let apiKey = try? KeychainHelper.readString(forKey: keyKey) {
                    configs[i].apiKey = apiKey
                }
            }
            self.providers = configs
        } else {
            self.providers = AIProviderType.allCases.map { ProviderConfig(type: $0) }
        }

        // Restore last selected provider
        if let savedTypeRaw = UserDefaults.standard.string(forKey: selectedProviderKey),
           let savedType = AIProviderType(rawValue: savedTypeRaw)
        {
            self.selectedProviderType = savedType
        } else {
            self.selectedProviderType = .zhipu  // Default fallback
        }

        if let savedPort = UserDefaults.standard.string(forKey: portKey), !savedPort.isEmpty {
            self.serverPort = savedPort
        }

        if let savedPrompt = UserDefaults.standard.string(forKey: customSystemPromptKey) {
            self.customSystemPrompt = savedPrompt
        }

        server.onLog = { [self] message in
            Task { @MainActor in
                self.logs.append(message)
                if self.logs.count > 200 {
                    self.logs.removeFirst()
                }
            }
        }

        server.stateDidChange = { [self] running, status in
            Task { @MainActor in
                self.isServerRunning = running
                self.serverStatus = status
            }
        }

        server.onModelUsed = { [self] model in
            Task { @MainActor in
                self.currentModelInUse = model
            }
        }
    }

    func saveProviders() {
        // Save API keys to Keychain
        for provider in providers {
            let keyKey = "api_key_\(provider.type.rawValue)"
            if !provider.apiKey.isEmpty {
                try? KeychainHelper.saveString(provider.apiKey, forKey: keyKey)
            } else {
                try? KeychainHelper.delete(forKey: keyKey)
            }
        }

        // Save provider structure (without API keys) to UserDefaults
        var configsToSave = providers
        for i in configsToSave.indices {
            configsToSave[i].apiKey = ""  // Clear API key before saving structure
        }
        if let data = try? JSONEncoder().encode(configsToSave) {
            UserDefaults.standard.set(data, forKey: configKey)
        }

        UserDefaults.standard.set(serverPort, forKey: portKey)
        UserDefaults.standard.set(selectedProviderType.rawValue, forKey: selectedProviderKey)
        UserDefaults.standard.set(customSystemPrompt, forKey: customSystemPromptKey)
    }

    func fetchModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }

        let config = selectedProvider
        let baseURL =
            config.apiURL.hasSuffix("/") ? String(config.apiURL.dropLast()) : config.apiURL
        guard let url = URL(string: "\(baseURL)/models") else {
            logs.append("Invalid URL: \(baseURL)/models")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataArray = json["data"] as? [[String: Any]]
            {
                let models = dataArray.compactMap { item -> ModelInfo? in
                    guard let id = item["id"] as? String else { return nil }
                    let ownedBy = item["owned_by"] as? String ?? config.type.displayName
                    return ModelInfo(id: id, ownedBy: ownedBy)
                }
                var updated = selectedProvider
                updated.models = models
                selectedProvider = updated
                logs.append("Fetched \(models.count) models from \(config.type.displayName)")
            }
        } catch {
            logs.append("Failed to fetch models: \(error.localizedDescription)")
        }
    }

    func testConnection() async {
        isTestingConnection = true
        lastTestResult = nil
        defer { isTestingConnection = false }

        let config = selectedProvider
        let baseURL =
            config.apiURL.hasSuffix("/") ? String(config.apiURL.dropLast()) : config.apiURL
        guard let url = URL(string: "\(baseURL)/models") else {
            lastTestResult = (false, "Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let dataArray = json["data"] as? [[String: Any]]
            {
                let modelCount = dataArray.count
                lastTestResult = (true, "Connected successfully (\(modelCount) models)")
                logs.append("✓ Connection test passed for \(config.type.displayName) - \(modelCount) models available")
            } else {
                lastTestResult = (false, "Invalid response format")
                logs.append("✗ Connection test failed: Invalid response format")
            }
        } catch {
            lastTestResult = (false, error.localizedDescription)
            logs.append("✗ Connection test failed: \(error.localizedDescription)")
        }
    }

    func toggleServer() {
        if isServerRunning {
            server.stop()
            isServerRunning = false
            serverStatus = "Stopped"
        } else {
            guard let port = UInt16(serverPort) else {
                serverStatus = "Invalid port"
                return
            }
            saveProviders()
            server.start(port: port, providers: providers, customSystemPrompt: customSystemPrompt)
        }
    }
}

struct ContentView: View {
    @State private var appState = AppState()
    @State private var isLogsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    providerSection
                    Divider()
                    serverSection
                }
                .padding()
            }

            logPanel
        }
        .frame(minWidth: 520, minHeight: 400)
    }

    // MARK: - Provider Configuration

    @ViewBuilder
    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Model Provider", systemImage: "gear")
                .font(.headline)

            HStack {
                Text("Provider")
                    .frame(width: 70, alignment: .trailing)
                Picker("", selection: $appState.selectedProviderType) {
                    ForEach(AIProviderType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text("API Key")
                    .frame(width: 70, alignment: .trailing)
                SecureField(
                    "Enter API Key",
                    text: Binding(
                        get: { appState.selectedProvider.apiKey },
                        set: { val in
                            var c = appState.selectedProvider
                            c.apiKey = val
                            appState.selectedProvider = c
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("API URL")
                    .frame(width: 70, alignment: .trailing)
                TextField(
                    "API URL",
                    text: Binding(
                        get: { appState.selectedProvider.apiURL },
                        set: { val in
                            var c = appState.selectedProvider
                            c.apiURL = val
                            appState.selectedProvider = c
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)
            }

            if !appState.selectedProvider.apiKey.isEmpty
                && !appState.selectedProvider.apiURL.isEmpty
            {
                HStack {
                    Spacer().frame(width: 74)
                    Button(action: { Task { await appState.testConnection() } }) {
                        HStack(spacing: 4) {
                            if appState.isTestingConnection {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(appState.isTestingConnection)

                    if let testResult = appState.lastTestResult {
                        HStack(spacing: 4) {
                            Image(systemName: testResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundColor(testResult.success ? .green : .red)
                            Text(testResult.message)
                                .font(.caption)
                                .foregroundColor(testResult.success ? .green : .red)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Proxy Server", systemImage: "server.rack")
                .font(.headline)

            HStack {
                Text("Port")
                    .frame(width: 70, alignment: .trailing)
                TextField("Port", text: $appState.serverPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(appState.isServerRunning)
                    .onChange(of: appState.serverPort) {
                        appState.saveProviders()
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("System\nPrompt")
                        .frame(width: 70, alignment: .trailing)
                        .multilineTextAlignment(.trailing)
                    TextEditor(text: $appState.customSystemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 60)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )
                        .disabled(appState.isServerRunning)
                        .onChange(of: appState.customSystemPrompt) {
                            appState.saveProviders()
                        }
                }
                HStack {
                    Spacer().frame(width: 74)
                    Text("This prompt will be injected as a system message into every request")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Status")
                    .frame(width: 70, alignment: .trailing)
                Circle()
                    .fill(appState.isServerRunning ? .green : .red)
                    .frame(width: 8, height: 8)
                Text(appState.serverStatus)
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            HStack {
                Spacer().frame(width: 74)
                Button(action: { appState.toggleServer() }) {
                    HStack(spacing: 6) {
                        Image(
                            systemName: appState.isServerRunning
                                ? "stop.circle.fill" : "play.circle.fill"
                        )
                        Text(appState.isServerRunning ? "Stop Server" : "Start Server")
                    }
                    .frame(minWidth: 120)
                }
                .controlSize(.large)
                .tint(appState.isServerRunning ? .red : .green)
            }

            if appState.isServerRunning {
                HStack {
                    Spacer().frame(width: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Access URLs:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("http://localhost:\(appState.serverPort)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            if appState.isServerRunning && !appState.currentModelInUse.isEmpty {
                HStack {
                    Spacer().frame(width: 74)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Current Model:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appState.currentModelInUse)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - Log Panel

    @ViewBuilder
    private var logPanel: some View {
        VStack(spacing: 0) {
            Divider()

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isLogsExpanded.toggle() } })
            {
                HStack {
                    Image(systemName: isLogsExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.gray)
                    Label("Logs", systemImage: "doc.text")
                        .font(.headline)
                        .foregroundStyle(.white)

                    if !appState.logs.isEmpty {
                        Text("(\(appState.logs.count))")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    Spacer()

                    if isLogsExpanded {
                        Button("Clear") {
                            appState.logs.removeAll()
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .foregroundStyle(.gray)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(Color.black)

            if isLogsExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(
                                Array(appState.logs.enumerated()), id: \.offset
                            ) { index, log in
                                Text(log)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .textSelection(.enabled)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 180)
                    .onChange(of: appState.logs.count) {
                        if let last = appState.logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .background(Color.black)
            }
        }
    }
}

#Preview {
    ContentView()
}
