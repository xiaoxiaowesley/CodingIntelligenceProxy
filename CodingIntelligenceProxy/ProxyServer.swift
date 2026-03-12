import Foundation
import NIOFoundationCompat
import Vapor

final class ProxyServer: @unchecked Sendable {

    private var app: Application?
    private var providers: [ProviderConfig] = []
    private var modelToProvider: [String: ProviderConfig] = [:]

    var onLog: (@Sendable (String) -> Void)?
    var stateDidChange: (@Sendable (Bool, String) -> Void)?
    var onModelUsed: (@Sendable (String) -> Void)?

    private func rebuildModelMapping() {
        modelToProvider = [:]
        for provider in providers where provider.isEnabled && !provider.apiKey.isEmpty {
            if !provider.selectedModel.isEmpty {
                modelToProvider[provider.selectedModel] = provider
            }
            for model in provider.models {
                modelToProvider[model.id] = provider
            }
        }
    }

    func start(port: UInt16, providers: [ProviderConfig], customSystemPrompt: String) {
        stop()
        self.providers = providers
        rebuildModelMapping()

        let mapping = self.modelToProvider
        let logFn: (@Sendable (String) -> Void)? = self.onLog
        let stateChangeFn: (@Sendable (Bool, String) -> Void)? = self.stateDidChange
        let modelUsedFn: (@Sendable (String) -> Void)? = self.onModelUsed
        let systemPrompt = customSystemPrompt

        Task.detached {
            @Sendable func logMessage(_ message: String) {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let timestamp = formatter.string(from: Date())
                logFn?("[\(timestamp)] \(message)")
            }

            do {
                let env = Environment(name: "production", arguments: ["serve"])
                let app = try await Application.make(env)
                await MainActor.run { self.app = app }

                app.http.server.configuration.port = Int(port)
                app.http.server.configuration.hostname = "0.0.0.0"

                // CORS middleware
                let cors = CORSMiddleware(configuration: .init(
                    allowedOrigin: .all,
                    allowedMethods: [.GET, .POST, .OPTIONS],
                    allowedHeaders: [.contentType, .authorization]
                ))
                app.middleware.use(cors)

                // Suppress Vapor's default console logging
                app.logger.logLevel = .error

                // Increase max body size (default 16KB is too small for chat requests)
                app.routes.defaultMaxBodySize = "50mb"

                // --- Routes ---

                app.get("health") { req -> Response in
                    logMessage("GET /health")
                    let json: [String: Any] = [
                        "status": "ok",
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "models": mapping.count,
                    ]
                    return try Self.jsonResponse(json, status: .ok)
                }

                app.get("v1", "models") { req -> Response in
                    logMessage("GET /v1/models")
                    var modelList: [[String: Any]] = []
                    for (modelId, provider) in mapping {
                        modelList.append([
                            "id": modelId,
                            "object": "model",
                            "created": 1_677_610_602,
                            "owned_by": provider.type.displayName,
                        ])
                    }
                    let json: [String: Any] = ["object": "list", "data": modelList]
                    return try Self.jsonResponse(json, status: .ok)
                }

                let chatHandler: @Sendable (Request) async throws -> Response = {
                    req in
                    try await Self.handleChat(
                        req: req, mapping: mapping, customSystemPrompt: systemPrompt,
                        logFn: logMessage, modelUsedFn: modelUsedFn)
                }

                app.post("v1", "chat", "completions", use: chatHandler)
                app.post("api", "v1", "chat", "completions", use: chatHandler)
                app.post("v1", "messages", use: chatHandler)

                try await app.startup()

                stateChangeFn?(true, "Running on port \(port)")
                logMessage("Server started on port \(port)")
            } catch {
                stateChangeFn?(false, "Failed: \(error.localizedDescription)")
                logMessage("Server failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        if let app {
            app.server.shutdown()
            Task.detached {
                try? await app.asyncShutdown()
            }
        }
        app = nil
        stateDidChange?(false, "Stopped")
    }

    // MARK: - Chat Completions Handler

    private static func handleChat(
        req: Request,
        mapping: [String: ProviderConfig],
        customSystemPrompt: String,
        logFn: @escaping @Sendable (String) -> Void,
        modelUsedFn: (@Sendable (String) -> Void)?
    ) async throws -> Response {
        guard let bodyBuffer = req.body.data else {
            throw Abort(.badRequest, reason: "Missing request body")
        }

        let bodyData = Data(buffer: bodyBuffer)
        guard
            let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
            let model = json["model"] as? String
        else {
            throw Abort(.badRequest, reason: "Missing required parameter: model")
        }

        // Report the model being used
        modelUsedFn?(model)

        guard let provider = mapping[model] else {
            let supported = mapping.keys.sorted().joined(separator: ", ")
            throw Abort(
                .notFound,
                reason: "Unsupported model: \(model). Supported: \(supported)")
        }

        let isStreaming = json["stream"] as? Bool ?? false
        logFn(
            "POST /v1/chat/completions -> \(provider.type.displayName), model: \(model), stream: \(isStreaming)"
        )

        // Strip empty tools array (some providers like Qwen reject tools: [])
        var forwardBody = json
        if let tools = forwardBody["tools"] as? [Any], tools.isEmpty {
            forwardBody.removeValue(forKey: "tools")
        }

        // Inject custom system prompt into messages
        if !customSystemPrompt.isEmpty,
            var messages = forwardBody["messages"] as? [[String: Any]]
        {
            let promptMessage: [String: Any] = [
                "role": "system",
                "content": customSystemPrompt,
            ]
            // Insert after the first system message, or at the beginning if none exists
            if let firstSystemIndex = messages.firstIndex(where: { ($0["role"] as? String) == "system" }) {
                messages.insert(promptMessage, at: firstSystemIndex + 1)
            } else {
                messages.insert(promptMessage, at: 0)
            }
            forwardBody["messages"] = messages
        }

        let forwardData = try JSONSerialization.data(withJSONObject: forwardBody)

        let apiURL =
            provider.apiURL.hasSuffix("/")
            ? String(provider.apiURL.dropLast()) : provider.apiURL
        guard let url = URL(string: "\(apiURL)/chat/completions") else {
            throw Abort(.internalServerError, reason: "Invalid provider URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.httpBody = forwardData
        urlRequest.timeoutInterval = 120

        if isStreaming {
            return try await forwardStreaming(urlRequest: urlRequest, logFn: logFn)
        } else {
            return try await forwardNonStreaming(urlRequest: urlRequest, logFn: logFn)
        }
    }

    // MARK: - Forwarding

    private static func forwardNonStreaming(
        urlRequest: URLRequest,
        logFn: @escaping @Sendable (String) -> Void
    ) async throws -> Response {
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        logFn("Provider responded with status: \(statusCode)")

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(
            status: HTTPResponseStatus(statusCode: statusCode),
            headers: headers,
            body: .init(data: data)
        )
    }

    private static func forwardStreaming(
        urlRequest: URLRequest,
        logFn: @escaping @Sendable (String) -> Void
    ) async throws -> Response {
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
        logFn("Provider streaming started, status: \(statusCode)")

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "text/event-stream")
        headers.add(name: .cacheControl, value: "no-cache")
        headers.add(name: .connection, value: "keep-alive")

        return Response(
            status: HTTPResponseStatus(statusCode: statusCode),
            headers: headers,
            body: .init(asyncStream: { writer in
                do {
                    for try await line in bytes.lines {
                        try await writer.write(.buffer(ByteBuffer(string: line + "\n")))
                    }
                    try await writer.write(.end)
                } catch {
                    logFn("Stream error: \(error.localizedDescription)")
                    try? await writer.write(.end)
                }
            })
        )
    }

    // MARK: - Helpers

    private static func jsonResponse(_ json: [String: Any], status: HTTPResponseStatus) throws
        -> Response
    {
        let data = try JSONSerialization.data(withJSONObject: json)
        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")
        return Response(status: status, headers: headers, body: .init(data: data))
    }
}
