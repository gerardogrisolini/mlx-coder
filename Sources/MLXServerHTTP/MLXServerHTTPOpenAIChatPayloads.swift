//
//  MLXServerHTTPOpenAIChatPayloads.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore

struct OpenAIChatCompletionRequest: Decodable, Sendable {
    var model: String?
    var messages: [OpenAIChatMessage]
    var stream: Bool?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var tools: [OpenAIChatToolDefinition]?
    var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case tools
        case reasoningEffort = "reasoning_effort"
    }

    var serverMessages: [MLXServerChatMessage] {
        messages.flatMap(\.serverMessages)
    }

    var toolSpecs: [ToolSpec]? {
        let specs = tools?.compactMap(\.toolSpec) ?? []
        return specs.isEmpty ? nil : specs
    }

    func thinkingSelection(
        for configuration: MLXServerModelThinkingConfiguration
    ) -> MLXServerThinkingSelection {
        configuration.selection(for: reasoningEffort)
    }

    func generateParameters(
        defaults: MLXServerModelGenerationDefaults,
        kvCacheSettings: MLXServerKVCacheSettings
    ) -> GenerateParameters {
        defaults.generateParameters(
            maxTokens: maxCompletionTokens ?? maxTokens,
            kvCacheSettings: kvCacheSettings
        )
    }
}

struct OpenAIChatMessage: Decodable, Sendable {
    var role: String
    var content: FlexibleMessageContent?
    var toolCallID: String?
    var toolCalls: [OpenAIChatMessageToolCall]?
    var reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
    }

    var serverMessage: MLXServerChatMessage {
        MLXServerChatMessage(
            role: serverRole,
            content: content?.text ?? "",
            imageURLs: content?.imageURLs ?? [],
            videoURLs: content?.videoURLs ?? []
        )
    }

    var serverMessages: [MLXServerChatMessage] {
        switch role {
        case "tool":
            return [.tool(content?.text ?? "", toolCallID: toolCallID)]
        case "assistant":
            var messages: [MLXServerChatMessage] = []
            if let reasoningContent, !reasoningContent.isEmpty {
                messages.append(.assistant(MLXServerReasoningTranscript.reasoningSummary(reasoningContent)))
            }
            let calls = (toolCalls ?? []).map(\.serverToolCall)
            let text = content?.text ?? ""
            if !text.isEmpty || !calls.isEmpty {
                messages.append(
                    MLXServerChatMessage(
                        role: .assistant,
                        content: text,
                        imageURLs: content?.imageURLs ?? [],
                        videoURLs: content?.videoURLs ?? [],
                        toolCalls: calls
                    )
                )
            }
            if messages.isEmpty {
                messages.append(serverMessage)
            }
            return messages
        default:
            return [serverMessage]
        }
    }

    private var serverRole: MLXServerChatMessage.Role {
        switch role {
        case "system", "developer":
            .system
        case "assistant":
            .assistant
        case "tool":
            .tool
        default:
            .user
        }
    }
}

struct OpenAIChatToolDefinition: Decodable, Sendable {
    var type: String
    var function: Function?

    struct Function: Decodable, Sendable {
        var name: String
        var description: String?
        var parameters: JSONValue?
        var strict: Bool?
    }

    var toolSpec: ToolSpec? {
        guard type == "function", let function else {
            return nil
        }
        let parameters = function.parameters?.sendableValue
            ?? ["type": "object", "properties": [:] as [String: any Sendable]] as [String: any Sendable]
        return [
            "type": "function",
            "function": [
                "name": function.name,
                "description": function.description ?? "",
                "parameters": parameters,
                "strict": function.strict ?? false
            ] as [String: any Sendable]
        ]
    }
}

struct OpenAIChatMessageToolCall: Decodable, Sendable {
    var id: String?
    var type: String?
    var function: Function

    struct Function: Decodable, Sendable {
        var name: String
        var arguments: String
    }

    var serverToolCall: MLXServerChatToolCall {
        MLXServerChatToolCall(
            id: id,
            name: function.name,
            arguments: MLXServerHTTPToolArguments.object(from: function.arguments)
        )
    }
}

struct ChatCompletionResponse: Encodable {
    var id: String = "chatcmpl-\(UUID().uuidString)"
    var object = "chat.completion"
    var created = Int(Date().timeIntervalSince1970)
    var model: String
    var choices: [Choice]
    var usage: Usage
    var mlxMetrics: MLXMetrics?

    init(
        model: String,
        text: String,
        toolCalls: [ToolCall] = [],
        emitsThinking: Bool = false,
        info: GenerateCompletionInfo?
    ) {
        self.model = model
        let content = ChatCompletionOutputContent(text: text, emitsThinking: emitsThinking)
        choices = [
            Choice(
                index: 0,
                message: Message(
                    role: "assistant",
                    content: content.visibleText,
                    reasoningContent: content.reasoningText,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls.map(ChatCompletionMessageToolCall.init)
                ),
                finishReason: toolCalls.isEmpty ? "stop" : "tool_calls"
            )
        ]
        usage = Usage(info: info)
        mlxMetrics = info.map(MLXMetrics.init)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case model
        case choices
        case usage
        case mlxMetrics = "mlx_metrics"
    }

    struct Choice: Encodable {
        var index: Int
        var message: Message
        var finishReason: String

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Encodable {
        var role: String
        var content: String?
        var reasoningContent: String?
        var toolCalls: [ChatCompletionMessageToolCall]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }
}

struct ChatCompletionMessageToolCall: Encodable {
    var id: String
    var type = "function"
    var function: Function

    init(_ toolCall: ToolCall) {
        id = ChatCompletionToolCallID.make()
        function = Function(
            name: toolCall.function.name,
            arguments: (try? ResponsesOutputBuilder.encodedJSONString(toolCall.function.arguments)) ?? "{}"
        )
    }

    init(id: String, name: String, arguments: String) {
        self.id = id
        function = Function(name: name, arguments: arguments)
    }

    struct Function: Encodable {
        var name: String
        var arguments: String
    }
}

enum ChatCompletionToolCallID {
    static func make() -> String {
        "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

struct ChatCompletionOutputContent {
    var visibleText: String
    var reasoningText: String?

    init(text: String, emitsThinking: Bool) {
        guard emitsThinking else {
            visibleText = text
            reasoningText = nil
            return
        }

        let fragments = AnthropicThinkingSplitter.collect(
            text,
            emitsThinking: true,
            startsInThinking: true
        )
        let reasoning = fragments
            .filter { $0.kind == .thinking }
            .map(\.text)
            .joined()
        visibleText = fragments
            .filter { $0.kind == .text }
            .map(\.text)
            .joined()
        reasoningText = reasoning.isEmpty ? nil : reasoning
    }
}

struct ChatCompletionChunk: Encodable {
    var id: String
    var object = "chat.completion.chunk"
    var created = Int(Date().timeIntervalSince1970)
    var model: String
    var choices: [Choice]

    static func role(id: String, model: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)])
    }

    static func delta(id: String, model: String, text: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(content: text), finishReason: nil)])
    }

    static func reasoningDelta(id: String, model: String, text: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(reasoningContent: text), finishReason: nil)])
    }

    static func toolCallDelta(
        id: String,
        model: String,
        index: Int,
        toolCallID: String,
        name: String,
        arguments: String
    ) -> Self {
        Self(
            id: id,
            model: model,
            choices: [
                .init(
                    index: 0,
                    delta: .init(
                        toolCalls: [
                            .init(
                                index: index,
                                id: toolCallID,
                                type: "function",
                                function: .init(name: name, arguments: arguments)
                            )
                        ]
                    ),
                    finishReason: nil
                )
            ]
        )
    }

    static func done(id: String, model: String, finishReason: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(), finishReason: finishReason)])
    }

    struct Choice: Encodable {
        var index: Int
        var delta: Delta
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Encodable {
        var role: String?
        var content: String?
        var reasoningContent: String?
        var toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Encodable {
        var index: Int
        var id: String?
        var type: String?
        var function: Function?

        struct Function: Encodable {
            var name: String?
            var arguments: String?
        }
    }
}

struct ChatCompletionStreamingContentWriter {
    private let writer: MLXServerNIOResponseWriter
    private let id: String
    private let model: String
    private let emitsThinking: Bool
    private var splitter: AnthropicThinkingSplitter
    private var nextToolCallIndex = 0
    private var emittedToolCall = false

    init(
        writer: MLXServerNIOResponseWriter,
        id: String,
        model: String,
        emitsThinking: Bool
    ) {
        self.writer = writer
        self.id = id
        self.model = model
        self.emitsThinking = emitsThinking
        splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
    }

    mutating func write(_ chunk: String) async throws {
        guard emitsThinking else {
            try await writer.sendSSE(data: ChatCompletionChunk.delta(id: id, model: model, text: chunk))
            return
        }

        for fragment in splitter.consume(chunk) {
            try await write(fragment)
        }
    }

    mutating func write(_ toolCall: ToolCall) async throws {
        if emitsThinking {
            for fragment in splitter.finish() {
                try await write(fragment)
            }
        }

        let toolCallID = ChatCompletionToolCallID.make()
        let arguments = (try? ResponsesOutputBuilder.encodedJSONString(toolCall.function.arguments)) ?? "{}"
        try await writer.sendSSE(
            data: ChatCompletionChunk.toolCallDelta(
                id: id,
                model: model,
                index: nextToolCallIndex,
                toolCallID: toolCallID,
                name: toolCall.function.name,
                arguments: arguments
            )
        )
        nextToolCallIndex += 1
        emittedToolCall = true
    }

    mutating func finish() async throws {
        if emitsThinking {
            for fragment in splitter.finish() {
                try await write(fragment)
            }
        }
        try await writer.sendSSE(
            data: ChatCompletionChunk.done(
                id: id,
                model: model,
                finishReason: emittedToolCall ? "tool_calls" : "stop"
            )
        )
    }

    private func write(_ fragment: AnthropicContentFragment) async throws {
        guard !fragment.text.isEmpty else {
            return
        }
        switch fragment.kind {
        case .text:
            try await writer.sendSSE(data: ChatCompletionChunk.delta(id: id, model: model, text: fragment.text))
        case .thinking:
            try await writer.sendSSE(
                data: ChatCompletionChunk.reasoningDelta(id: id, model: model, text: fragment.text)
            )
        }
    }
}
