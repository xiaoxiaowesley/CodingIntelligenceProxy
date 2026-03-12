import Foundation

enum AIProviderType: String, CaseIterable, Codable, Identifiable {
    case zhipu
    case kimi
    case gemini
    case qwen
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhipu: "智谱AI"
        case .kimi: "Kimi"
        case .gemini: "Gemini"
        case .qwen: "Qwen"
        case .custom: "Custom"
        }
    }

    var defaultURL: String {
        switch self {
        case .zhipu: "https://open.bigmodel.cn/api/paas/v4"
        case .kimi: "https://api.moonshot.cn/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta/openai"
        case .qwen: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        case .custom: ""
        }
    }
}

struct ModelInfo: Identifiable, Codable, Hashable {
    var id: String
    var ownedBy: String
}

struct ProviderConfig: Identifiable, Codable {
    var id: UUID
    var type: AIProviderType
    var apiKey: String
    var apiURL: String
    var selectedModel: String
    var models: [ModelInfo]
    var isEnabled: Bool

    init(type: AIProviderType) {
        self.id = UUID()
        self.type = type
        self.apiKey = ""
        self.apiURL = type.defaultURL
        self.selectedModel = ""
        self.models = []
        self.isEnabled = true
    }
}
