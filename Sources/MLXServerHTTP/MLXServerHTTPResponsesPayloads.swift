//
//  MLXServerHTTPResponsesPayloads.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore

struct ResponsesRequest: Decodable, Sendable {
    var model: String?
    var instructions: FlexibleMessageContent?
    var input: ResponsesInput
    var stream: Bool?
    var maxOutputTokens: Int?
        var tools: [ResponsesToolDefinition]?
    var reasoning: ResponsesReasoningConfiguration?
    var sessionID: String?
    var promptCacheKey: String?

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case stream
        case maxOutputTokens = "max_output_tokens"
                case tools
        case reasoning
        case sessionID = "session_id"
        case promptCacheKey = "prompt_cache_key"
    }

    var effectiveSessionID: String? {
        sessionID ?? promptCacheKey
    }

    var serverMessages: [MLXServerChatMessage] {
        var messages = input.messages
        if let instructions, !instructions.text.isEmpty {
            messages.insert(.system(instructions.text), at: 0)
        }
        return messages.mlxServerSystemMessagesFirst()
    }

    var toolSpecs: [ToolSpec]? {
        let specs = tools?.compactMap(\.toolSpec) ?? []
        return specs.isEmpty ? nil : specs
    }

    func thinkingSelection(
        for configuration: MLXServerModelThinkingConfiguration
    ) -> MLXServerThinkingSelection {
        guard let reasoning else {
            return .off
        }
        return configuration.selection(for: reasoning.selectionProtocolValue)
    }

    func generateParameters(
        defaults: MLXServerModelGenerationDefaults,
        kvCacheSettings: MLXServerKVCacheSettings
    ) -> GenerateParameters {
        defaults.generateParameters(
            maxTokens: maxOutputTokens,
            kvCacheSettings: kvCacheSettings
        )
    }
}

enum ResponsesInput: Decodable, Sendable {
    case text(String)
    case messages([ResponsesInputItem])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else if let message = try? container.decode(ResponsesInputItem.self) {
            self = .messages([message])
        } else {
            self = .messages(try container.decode([ResponsesInputItem].self))
        }
    }

    var messages: [MLXServerChatMessage] {
        switch self {
        case .text(let text):
            [.user(text)]
        case .messages(let messages):
            messages.flatMap(\.serverMessages)
        }
    }
}

struct ResponsesInputItem: Decodable, Sendable {
    var type: String?
    var role: String?
    var content: FlexibleMessageContent?
    var callID: String?
    var output: FlexibleMessageContent?
    var name: String?
    var arguments: FlexibleJSONString?
    var summary: [ResponsesReasoningSummaryContent]?

    enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case callID = "call_id"
        case output
        case name
        case arguments
        case summary
    }

    var serverMessages: [MLXServerChatMessage] {
        switch type {
        case "function_call_output":
            return [.tool(output?.text ?? "", toolCallID: callID)]
        case "function_call":
            return [
                MLXServerChatMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        MLXServerChatToolCall(
                            id: callID,
                            name: name ?? "",
                            arguments: MLXServerHTTPToolArguments.object(from: arguments?.value)
                        )
                    ]
                )
            ]
        case "reasoning":
            let text = summary?.map(\.text).joined(separator: "\n") ?? ""
            guard !text.isEmpty else {
                return []
            }
            return [.assistant(MLXServerReasoningTranscript.reasoningSummary(text))]
        default:
            guard let role else {
                return content.map { [.user($0.text)] } ?? []
            }
            return [
                MLXServerChatMessage(
                    role: serverRole(for: role),
                    content: content?.text ?? "",
                    imageURLs: content?.imageURLs ?? [],
                    videoURLs: content?.videoURLs ?? []
                )
            ]
        }
    }

    private func serverRole(for role: String) -> MLXServerChatMessage.Role {
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

extension Array where Element == MLXServerChatMessage {
    func mlxServerSystemMessagesFirst() -> [MLXServerChatMessage] {
        let systemText = filter { $0.role == .system }
            .map(\.content)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !systemText.isEmpty else {
            return self
        }

        return [.system(systemText)] + filter { $0.role != .system }
    }
}

struct ResponsesReasoningSummaryContent: Decodable, Sendable {
    var type: String?
    var text: String

    enum CodingKeys: String, CodingKey {
        case type
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            type = nil
            text = string
            return
        }

        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        type = try keyed.decodeIfPresent(String.self, forKey: .type)
        text = try keyed.decodeIfPresent(String.self, forKey: .text) ?? ""
    }
}

struct FlexibleJSONString: Decodable, Sendable {
    var value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
            return
        }

        let json = try container.decode(JSONValue.self)
        value = (try? ResponsesOutputBuilder.encodedJSONString(json)) ?? "{}"
    }
}

struct ResponsesToolDefinition: Decodable, Sendable {
    var type: String
    var name: String?
    var description: String?
    var parameters: JSONValue?
    var strict: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case description
        case parameters
        case strict
        case function
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        parameters = try container.decodeIfPresent(JSONValue.self, forKey: .parameters)
        strict = try container.decodeIfPresent(Bool.self, forKey: .strict)

        if let function = try container.decodeIfPresent(Function.self, forKey: .function) {
            name = function.name ?? name
            description = function.description ?? description
            parameters = function.parameters ?? parameters
            strict = function.strict ?? strict
        }
    }

    struct Function: Decodable, Sendable {
        var name: String?
        var description: String?
        var parameters: JSONValue?
        var strict: Bool?
    }

    var toolSpec: ToolSpec? {
        guard type == "function", let name else {
            return nil
        }
        let parameters = parameters?.sendableValue
            ?? ["type": "object", "properties": [:] as [String: any Sendable]] as [String: any Sendable]
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description ?? "",
                "parameters": parameters,
                "strict": strict ?? false
            ] as [String: any Sendable]
        ]
    }
}

struct ResponsesReasoningConfiguration: Decodable, Sendable {
    var enabled: Bool?
    var effort: String?
    var summary: String?

    var emitsThinking: Bool {
        if enabled == false {
            return false
        }
        guard summary != "none", effort != "none" else {
            return false
        }
        return enabled == true || summary != nil || effort != nil
    }

    var selectionProtocolValue: String? {
        emitsThinking ? (effort ?? "enabled") : "none"
    }
}

struct ResponsesResponse: Encodable {
    var id = "resp-\(UUID().uuidString)"
    var object = "response"
    var createdAt = Int(Date().timeIntervalSince1970)
    var status = "completed"
    var model: String
    var output: [ResponsesOutputItem]
    var usage: ResponsesUsage
    var mlxMetrics: MLXMetrics?

    init(
        id: String = "resp-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        model: String,
        text: String,
        toolCalls: [ToolCall] = [],
        emitsThinking: Bool = false,
        info: GenerateCompletionInfo?
    ) {
        self.id = id
        self.model = model
        output = ResponsesOutputBuilder.outputItems(
            text: text,
            toolCalls: toolCalls,
            emitsThinking: emitsThinking
        )
        usage = ResponsesUsage(info: info)
        mlxMetrics = info.map(MLXMetrics.init)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case status
        case model
        case output
        case usage
        case mlxMetrics = "mlx_metrics"
    }
}

enum ResponsesOutputBuilder {
    static func outputItems(
        text: String,
        toolCalls: [ToolCall],
        emitsThinking: Bool
    ) -> [ResponsesOutputItem] {
        var output: [ResponsesOutputItem] = []
        let fragments = AnthropicThinkingSplitter.collect(
            text,
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
        let reasoning = fragments
            .filter { $0.kind == .thinking }
            .map(\.text)
            .joined()
        let visibleText = fragments
            .filter { $0.kind == .text }
            .map(\.text)
            .joined()

        if !reasoning.isEmpty {
            output.append(.reasoning(id: responseReasoningID(), status: "completed", summary: reasoning))
        }
        if !visibleText.isEmpty {
            output.append(.message(id: responseMessageID(), status: "completed", text: visibleText))
        }
        output.append(contentsOf: toolCalls.map { toolCall in
            .functionCall(
                id: responseFunctionCallID(),
                callID: responseCallID(),
                status: "completed",
                name: toolCall.function.name,
                arguments: (try? encodedJSONString(toolCall.function.arguments)) ?? "{}"
            )
        })
        return output
    }

    static func responseMessageID() -> String {
        "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func responseReasoningID() -> String {
        "rs_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func responseFunctionCallID() -> String {
        "fc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func responseCallID() -> String {
        "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

enum ResponsesOutputItem: Encodable {
    case message(id: String, status: String, text: String)
    case reasoning(id: String, status: String, summary: String)
    case functionCall(id: String, callID: String, status: String, name: String, arguments: String)

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case status
        case role
        case content
        case summary
        case callID = "call_id"
        case name
        case arguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let id, let status, let text):
            try container.encode(id, forKey: .id)
            try container.encode("message", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode("assistant", forKey: .role)
            let content = text.isEmpty ? [] : [ResponsesContentPart.outputText(text)]
            try container.encode(content, forKey: .content)
        case .reasoning(let id, let status, let summary):
            try container.encode(id, forKey: .id)
            try container.encode("reasoning", forKey: .type)
            try container.encode(status, forKey: .status)
            let content = summary.isEmpty ? [] : [ResponsesContentPart.summaryText(summary)]
            try container.encode(content, forKey: .summary)
        case .functionCall(let id, let callID, let status, let name, let arguments):
            try container.encode(id, forKey: .id)
            try container.encode("function_call", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

enum ResponsesContentPart: Encodable {
    case outputText(String)
    case summaryText(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .outputText(let text):
            try container.encode("output_text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode([String](), forKey: .annotations)
        case .summaryText(let text):
            try container.encode("summary_text", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

struct ResponsesOutputTextDelta: Encodable {
    var type = "response.output_text.delta"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var delta: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesStreamingContentWriter {
    private let writer: MLXServerNIOResponseWriter
    private let responseID: String
    private let model: String
    private var splitter: AnthropicThinkingSplitter
    private var sequenceNumber = 0
    private var nextOutputIndex = 0
    private var currentItem: ResponsesStreamItem?
    private var outputItems: [ResponsesOutputItem] = []

    init(
        writer: MLXServerNIOResponseWriter,
        responseID: String,
        model: String,
        emitsThinking: Bool
    ) {
        self.writer = writer
        self.responseID = responseID
        self.model = model
        splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
    }

    mutating func start() async throws {
        try await send(
            event: "response.created",
            data: ResponsesLifecycleEvent(
                type: "response.created",
                response: ResponsesStreamResponse(id: responseID, model: model, status: "in_progress"),
                sequenceNumber: nextSequenceNumber()
            )
        )
        try await send(
            event: "response.in_progress",
            data: ResponsesLifecycleEvent(
                type: "response.in_progress",
                response: ResponsesStreamResponse(id: responseID, model: model, status: "in_progress"),
                sequenceNumber: nextSequenceNumber()
            )
        )
    }

    mutating func write(_ chunk: String) async throws {
        for fragment in splitter.consume(chunk) {
            try await write(fragment)
        }
    }

    mutating func write(_ toolCall: ToolCall) async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentItem()

        let itemID = ResponsesOutputBuilder.responseFunctionCallID()
        let callID = ResponsesOutputBuilder.responseCallID()
        let outputIndex = nextOutputIndex
        nextOutputIndex += 1
        let arguments = (try? ResponsesOutputBuilder.encodedJSONString(toolCall.function.arguments)) ?? "{}"

        try await send(
            event: "response.output_item.added",
            data: ResponsesOutputItemAdded(
                responseID: responseID,
                outputIndex: outputIndex,
                item: .functionCall(
                    id: itemID,
                    callID: callID,
                    status: "in_progress",
                    name: toolCall.function.name,
                    arguments: ""
                ),
                sequenceNumber: nextSequenceNumber()
            )
        )
        try await send(
            event: "response.function_call_arguments.delta",
            data: ResponsesFunctionCallArgumentsDelta(
                responseID: responseID,
                itemID: itemID,
                outputIndex: outputIndex,
                delta: arguments,
                sequenceNumber: nextSequenceNumber()
            )
        )
        try await send(
            event: "response.function_call_arguments.done",
            data: ResponsesFunctionCallArgumentsDone(
                responseID: responseID,
                itemID: itemID,
                outputIndex: outputIndex,
                name: toolCall.function.name,
                arguments: arguments,
                sequenceNumber: nextSequenceNumber()
            )
        )

        let item = ResponsesOutputItem.functionCall(
            id: itemID,
            callID: callID,
            status: "completed",
            name: toolCall.function.name,
            arguments: arguments
        )
        try await send(
            event: "response.output_item.done",
            data: ResponsesOutputItemDone(
                responseID: responseID,
                outputIndex: outputIndex,
                item: item,
                sequenceNumber: nextSequenceNumber()
            )
        )
        outputItems.append(item)
    }

    mutating func finish(info: GenerateCompletionInfo?) async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentItem()
        try await send(
            event: "response.completed",
            data: ResponsesLifecycleEvent(
                type: "response.completed",
                response: ResponsesStreamResponse(
                    id: responseID,
                    model: model,
                    status: "completed",
                    output: outputItems,
                    usage: ResponsesUsage(info: info),
                    mlxMetrics: info.map(MLXMetrics.init)
                ),
                sequenceNumber: nextSequenceNumber()
            )
        )
    }

    private mutating func write(_ fragment: AnthropicContentFragment) async throws {
        guard !fragment.text.isEmpty else {
            return
        }
        if currentItem?.kind != fragment.kind {
            try await stopCurrentItem()
            try await startItem(kind: fragment.kind)
        }
        guard var item = currentItem else {
            return
        }
        item.text += fragment.text
        currentItem = item

        switch item.kind {
        case .text:
            try await send(
                event: "response.output_text.delta",
                data: ResponsesOutputTextDelta(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    delta: fragment.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
        case .thinking:
            try await send(
                event: "response.reasoning_summary_text.delta",
                data: ResponsesReasoningSummaryTextDelta(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    delta: fragment.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
        }
    }

    private mutating func startItem(kind: AnthropicContentFragment.Kind) async throws {
        let item = ResponsesStreamItem(
            kind: kind,
            id: kind == .text
                ? ResponsesOutputBuilder.responseMessageID()
                : ResponsesOutputBuilder.responseReasoningID(),
            outputIndex: nextOutputIndex
        )
        currentItem = item
        nextOutputIndex += 1

        let outputItem: ResponsesOutputItem = kind == .text
            ? .message(id: item.id, status: "in_progress", text: "")
            : .reasoning(id: item.id, status: "in_progress", summary: "")
        try await send(
            event: "response.output_item.added",
            data: ResponsesOutputItemAdded(
                responseID: responseID,
                outputIndex: item.outputIndex,
                item: outputItem,
                sequenceNumber: nextSequenceNumber()
            )
        )

        switch kind {
        case .text:
            try await send(
                event: "response.content_part.added",
                data: ResponsesContentPartAdded(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    part: .outputText(""),
                    sequenceNumber: nextSequenceNumber()
                )
            )
        case .thinking:
            try await send(
                event: "response.reasoning_summary_part.added",
                data: ResponsesReasoningSummaryPartAdded(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    part: .summaryText(""),
                    sequenceNumber: nextSequenceNumber()
                )
            )
        }
    }

    private mutating func stopCurrentItem() async throws {
        guard let item = currentItem else {
            return
        }

        let outputItem: ResponsesOutputItem
        switch item.kind {
        case .text:
            try await send(
                event: "response.output_text.done",
                data: ResponsesOutputTextDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    text: item.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
            try await send(
                event: "response.content_part.done",
                data: ResponsesContentPartDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    part: .outputText(item.text),
                    sequenceNumber: nextSequenceNumber()
                )
            )
            outputItem = .message(id: item.id, status: "completed", text: item.text)
        case .thinking:
            try await send(
                event: "response.reasoning_summary_text.done",
                data: ResponsesReasoningSummaryTextDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    text: item.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
            try await send(
                event: "response.reasoning_summary_part.done",
                data: ResponsesReasoningSummaryPartDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    part: .summaryText(item.text),
                    sequenceNumber: nextSequenceNumber()
                )
            )
            outputItem = .reasoning(id: item.id, status: "completed", summary: item.text)
        }

        try await send(
            event: "response.output_item.done",
            data: ResponsesOutputItemDone(
                responseID: responseID,
                outputIndex: item.outputIndex,
                item: outputItem,
                sequenceNumber: nextSequenceNumber()
            )
        )
        outputItems.append(outputItem)
        currentItem = nil
    }

    private mutating func nextSequenceNumber() -> Int {
        sequenceNumber += 1
        return sequenceNumber
    }

    private func send<T: Encodable>(event: String, data: T) async throws {
        try await writer.sendSSE(event: event, data: data)
    }
}

struct ResponsesStreamItem {
    var kind: AnthropicContentFragment.Kind
    var id: String
    var outputIndex: Int
    var text = ""
}

struct ResponsesStreamResponse: Encodable {
    var id: String
    var object = "response"
    var createdAt = Int(Date().timeIntervalSince1970)
    var status: String
    var model: String
    var output: [ResponsesOutputItem]
    var usage: ResponsesUsage?
    var mlxMetrics: MLXMetrics?

    init(
        id: String,
        model: String,
        status: String,
        output: [ResponsesOutputItem] = [],
        usage: ResponsesUsage? = nil,
        mlxMetrics: MLXMetrics? = nil
    ) {
        self.id = id
        self.status = status
        self.model = model
        self.output = output
        self.usage = usage
        self.mlxMetrics = mlxMetrics
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case status
        case model
        case output
        case usage
        case mlxMetrics = "mlx_metrics"
    }
}

struct ResponsesLifecycleEvent: Encodable {
    var type: String
    var response: ResponsesStreamResponse
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case response
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesOutputItemAdded: Encodable {
    var type = "response.output_item.added"
    var responseID: String
    var outputIndex: Int
    var item: ResponsesOutputItem
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case outputIndex = "output_index"
        case item
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesOutputItemDone: Encodable {
    var type = "response.output_item.done"
    var responseID: String
    var outputIndex: Int
    var item: ResponsesOutputItem
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case outputIndex = "output_index"
        case item
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesContentPartAdded: Encodable {
    var type = "response.content_part.added"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesContentPartDone: Encodable {
    var type = "response.content_part.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesOutputTextDone: Encodable {
    var type = "response.output_text.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var text: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case text
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesReasoningSummaryPartAdded: Encodable {
    var type = "response.reasoning_summary_part.added"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesReasoningSummaryPartDone: Encodable {
    var type = "response.reasoning_summary_part.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesReasoningSummaryTextDelta: Encodable {
    var type = "response.reasoning_summary_text.delta"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var delta: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case delta
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesReasoningSummaryTextDone: Encodable {
    var type = "response.reasoning_summary_text.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var text: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case text
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesFunctionCallArgumentsDelta: Encodable {
    var type = "response.function_call_arguments.delta"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var delta: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case delta
        case sequenceNumber = "sequence_number"
    }
}

struct ResponsesFunctionCallArgumentsDone: Encodable {
    var type = "response.function_call_arguments.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var name: String
    var arguments: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case name
        case arguments
        case sequenceNumber = "sequence_number"
    }
}
