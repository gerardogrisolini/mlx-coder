//
//  MLXCoderSetupRunner+Types.swift
//  mlx-coder
//

import Foundation
import MLXCoderCore

struct SetupSectionOption {
    let section: SetupSection
    let detail: String?
}

struct SetupSectionConfigurationResult {
    var manifest: AgentSettingsManifest?
    var additionalResult: MLXCoderSetupAdditionalSectionResult = .unchanged
}

enum SetupSection: Equatable {
    case providersAndModels
    case defaultModelSettings
    case defaultModel
    case defaultThinking
    case telegram
    case voice
    case agents
    case additionalGroup(Int, title: String, aliases: Set<String>)
    case finish

    var title: String {
        switch self {
        case .providersAndModels:
            return "Providers and models"
        case .defaultModelSettings:
            return "Default model"
        case .defaultModel:
            return "Default model"
        case .defaultThinking:
            return "Default thinking"
        case .telegram:
            return "Telegram remote control"
        case .voice:
            return "Local voice tools"
        case .agents:
            return "Agents"
        case .additionalGroup(_, let title, _):
            return title
        case .finish:
            return "Finish setup"
        }
    }

    var requiresConfiguredModels: Bool {
        switch self {
        case .providersAndModels, .agents, .additionalGroup, .finish:
            return false
        case .defaultModelSettings, .defaultModel, .defaultThinking, .telegram, .voice:
            return true
        }
    }

    var isAdditional: Bool {
        if case .additionalGroup = self {
            return true
        }
        return false
    }

    func matches(_ value: String) -> Bool {
        aliases.contains(value)
    }

    private var aliases: Set<String> {
        switch self {
        case .providersAndModels:
            return ["providers", "provider", "models", "model", "providers and models", "providers/models", "remote"]
        case .defaultModelSettings:
            return ["default", "default model", "selected model", "model default", "thinking", "default thinking"]
        case .defaultModel:
            return ["default", "default model", "selected model", "model default"]
        case .defaultThinking:
            return ["thinking", "default thinking", "reasoning", "thinking default"]
        case .telegram:
            return ["telegram", "remote control", "bot"]
        case .voice:
            return ["voice", "local voice", "voice tools", "speech"]
        case .agents:
            return ["agents", "agent", "profiles", "agent profiles"]
        case .additionalGroup(_, _, let aliases):
            return aliases
        case .finish:
            return ["finish", "done", "exit", "quit", "end", "stop"]
        }
    }
}

struct VoiceSetupOption {
    let value: String
    let title: String
    let detail: String?
    let aliases: [String]

    init(
        value: String,
        title: String,
        detail: String? = nil,
        aliases: [String] = []
    ) {
        self.value = value
        self.title = title
        self.detail = detail
        self.aliases = aliases
    }

    func matches(_ rawValue: String?) -> Bool {
        guard let value = rawValue?.nilIfBlank?.lowercased() else {
            return false
        }
        return self.value.lowercased() == value
            || title.lowercased() == value
            || aliases.contains { $0.lowercased() == value }
    }
}

struct SetupProviderInput {
    let id: UUID
    let name: String
    let baseURL: String
    let chatEndpoint: AgentRemoteChatEndpoint
    let apiKey: String?
    let models: [AgentSettingsModelManifest]
}

enum SetupProviderKind {
    case remoteAPI
    case chatGPTSubscription
    case anthropicSubscription
}

enum MLXCoderSetupError: LocalizedError {
    case nonInteractiveTerminal
    case cancelled
    case emptyRequiredValue(String)
    case invalidChoice(String)
    case noModelsConfigured
    case noRemoteModelsReturned
    case chatGPTSubscriptionUnsupported
    case anthropicSubscriptionUnsupported

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Setup requires an interactive terminal."
        case .cancelled:
            return "Setup cancelled."
        case let .emptyRequiredValue(label):
            return "\(label) is required."
        case let .invalidChoice(value):
            return "Invalid setup choice: \(value)"
        case .noModelsConfigured:
            return "At least one provider model is required."
        case .noRemoteModelsReturned:
            return "The server did not return any models from /models."
        case .chatGPTSubscriptionUnsupported:
            return "ChatGPT Subscription setup is available on macOS."
        case .anthropicSubscriptionUnsupported:
            return "Claude Subscription setup is available on macOS."
        }
    }
}
