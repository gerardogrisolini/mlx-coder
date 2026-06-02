//
//  MLXServerHTTPResponseMetadata.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore

struct Usage: Encodable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    init(info: GenerateCompletionInfo?) {
        promptTokens = info?.promptTokenCount ?? 0
        completionTokens = info?.generationTokenCount ?? 0
        totalTokens = promptTokens + completionTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

struct ResponsesUsage: Encodable {
    var inputTokens: Int
    var inputTokensDetails: InputTokensDetails
    var outputTokens: Int
    var outputTokensDetails: OutputTokensDetails
    var totalTokens: Int

    init(info: GenerateCompletionInfo?) {
        inputTokens = info?.promptTokenCount ?? 0
        inputTokensDetails = InputTokensDetails(cachedTokens: 0)
        outputTokens = info?.generationTokenCount ?? 0
        outputTokensDetails = OutputTokensDetails(reasoningTokens: 0)
        totalTokens = inputTokens + outputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case inputTokensDetails = "input_tokens_details"
        case outputTokens = "output_tokens"
        case outputTokensDetails = "output_tokens_details"
        case totalTokens = "total_tokens"
    }

    struct InputTokensDetails: Encodable {
        var cachedTokens: Int

        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }

    struct OutputTokensDetails: Encodable {
        var reasoningTokens: Int

        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }
}

struct MLXMetrics: Encodable {
    var promptTime: Double
    var generationTime: Double
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double

    init(info: GenerateCompletionInfo) {
        promptTime = info.promptTime
        generationTime = info.generateTime
        promptTokensPerSecond = info.promptTokensPerSecond
        generationTokensPerSecond = info.tokensPerSecond
    }

    enum CodingKeys: String, CodingKey {
        case promptTime = "prompt_time"
        case generationTime = "generation_time"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
    }
}

struct AnthropicUsage: Encodable {
    var inputTokens: Int
    var outputTokens: Int

    init(info: GenerateCompletionInfo?) {
        inputTokens = info?.promptTokenCount ?? 0
        outputTokens = info?.generationTokenCount ?? 0
    }

    init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

struct ModelsResponse: Encodable {
    var object = "list"

    var data: [Model]

    init(models: [MLXServerModelDescriptor]) {
        self.data = models.map { model in
            Model(
                id: model.id,
                ownedBy: Self.owner(for: model.id),
                thinking: model.thinking.supportsThinking ? model.thinking : nil
            )
        }
    }

    private static func owner(for id: String) -> String {
        guard let owner = id.split(separator: "/", maxSplits: 1).first, !owner.isEmpty else {
            return "local"
        }
        return String(owner)
    }

    struct Model: Encodable {
        var id: String
        var object = "model"
        var created = 0
        var ownedBy: String
        var thinking: MLXServerModelThinkingConfiguration?

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case created
            case ownedBy = "owned_by"
            case thinking
        }
    }
}

struct ErrorResponse: Encodable {
    var error: ErrorBody

    struct ErrorBody: Encodable {
        var message: String
        var type: String
    }
}
