//
//  MLXServerHTTPAnthropicPayloads.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore

struct AnthropicMessagesRequest: Decodable, Sendable {
    var model: String?
    var maxTokens: Int?
    var system: FlexibleMessageContent?
    var messages: [AnthropicInputMessage]
    var stream: Bool?
        var tools: [AnthropicToolDefinition]?
    var thinking: AnthropicThinkingConfiguration?
    var sessionID: String?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
                case tools
        case thinking
        case sessionID = "session_id"
    }

    var effectiveSessionID: String? {
        sessionID
    }

    var serverMessages: [MLXServerChatMessage] {
        var result: [MLXServerChatMessage] = []
        if let systemText = system?.anthropicSystemText, !systemText.isEmpty {
            result.append(.system(systemText))
        }
        result.append(contentsOf: messages.flatMap(\.serverMessages))
        return result
    }

    var toolSpecs: [ToolSpec]? {
        let specs = tools?.compactMap(\.toolSpec) ?? []
        return specs.isEmpty ? nil : specs
    }

    func thinkingSelection(
        for configuration: MLXServerModelThinkingConfiguration
    ) -> MLXServerThinkingSelection {
        guard thinking?.emitsThinking == true else {
            return .off
        }
        return configuration.defaultEnabledSelection()
    }

    func generateParameters(
        defaults: MLXServerModelGenerationDefaults,
        kvCacheSettings: MLXServerKVCacheSettings
    ) -> GenerateParameters {
        defaults.generateParameters(
            maxTokens: maxTokens,
            kvCacheSettings: kvCacheSettings
        )
    }
}

struct AnthropicInputMessage: Decodable, Sendable {
    var role: String
    var content: FlexibleMessageContent

    var serverMessage: MLXServerChatMessage {
        MLXServerChatMessage(
            role: serverRole,
            content: content.text,
            imageURLs: content.imageURLs,
            videoURLs: content.videoURLs
        )
    }

    var serverMessages: [MLXServerChatMessage] {
        if role == "assistant" {
            var result: [MLXServerChatMessage] = []
            if !content.thinkingText.isEmpty {
                result.append(.assistant(MLXServerReasoningTranscript.reasoningSummary(content.thinkingText)))
            }
            if !content.text.isEmpty || !content.toolUses.isEmpty {
                result.append(
                    MLXServerChatMessage(
                        role: .assistant,
                        content: content.text,
                        imageURLs: content.imageURLs,
                        videoURLs: content.videoURLs,
                        toolCalls: content.toolUses
                    )
                )
            }
            return result.isEmpty ? [serverMessage] : result
        }

        if role == "user", !content.toolResults.isEmpty {
            var result: [MLXServerChatMessage] = []
            if !content.text.isEmpty {
                result.append(
                    MLXServerChatMessage(
                        role: .user,
                        content: content.text,
                        imageURLs: content.imageURLs,
                        videoURLs: content.videoURLs
                    )
                )
            }
            result.append(contentsOf: content.toolResults)
            return result
        }
        return [serverMessage]
    }

    private var serverRole: MLXServerChatMessage.Role {
        switch role {
        case "system":
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

struct AnthropicThinkingConfiguration: Decodable, Sendable {
    var type: String?
    var display: String?

    var emitsThinking: Bool {
        guard type != "disabled", display != "omitted" else {
            return false
        }
        return type != nil || display != nil
    }
}

struct AnthropicToolDefinition: Decodable, Sendable {
    var name: String?
    var description: String?
    var inputSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    var toolSpec: ToolSpec? {
        guard let name else {
            return nil
        }

        let parameters = inputSchema?.sendableValue
            ?? ["type": "object", "properties": [:] as [String: any Sendable]] as [String: any Sendable]

        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description ?? "",
                "parameters": parameters
            ] as [String: any Sendable]
        ]
    }
}

struct AnthropicStreamingContentWriter {
    private let writer: MLXServerNIOResponseWriter
    private var splitter: AnthropicThinkingSplitter
    private var currentBlock: AnthropicStreamBlock?
    private var nextIndex = 0

    init(writer: MLXServerNIOResponseWriter, emitsThinking: Bool) {
        self.writer = writer
        splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
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
        try await stopCurrentBlock()

        let index = nextIndex
        nextIndex += 1
        let id = AnthropicToolUseID.make()
        try await writer.sendSSE(
            event: "content_block_start",
            data: AnthropicContentBlockStart(
                index: index,
                contentBlock: .toolUse(id: id, name: toolCall.function.name)
            )
        )
        try await writer.sendSSE(
            event: "content_block_delta",
            data: AnthropicContentBlockDelta(
                index: index,
                delta: .inputJSON(try encodedJSONString(toolCall.function.arguments))
            )
        )
        try await writer.sendSSE(
            event: "content_block_stop",
            data: AnthropicIndexedEvent(type: "content_block_stop", index: index)
        )
    }

    mutating func finish() async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentBlock()
    }

    private mutating func write(_ fragment: AnthropicContentFragment) async throws {
        guard !fragment.text.isEmpty else {
            return
        }
        if currentBlock?.kind != fragment.kind {
            try await stopCurrentBlock()
            try await startBlock(AnthropicStreamBlock(kind: fragment.kind))
        }
        guard let block = currentBlock else {
            return
        }
        try await writer.sendSSE(
            event: "content_block_delta",
            data: AnthropicContentBlockDelta(
                index: block.index,
                delta: fragment.kind == .text
                    ? .text(fragment.text)
                    : .thinking(fragment.text)
            )
        )
    }

    private mutating func startBlock(_ block: AnthropicStreamBlock) async throws {
        var block = block
        block.index = nextIndex
        nextIndex += 1
        currentBlock = block

        try await writer.sendSSE(
            event: "content_block_start",
            data: AnthropicContentBlockStart(
                index: block.index,
                contentBlock: block.kind == .text ? .text : .thinking
            )
        )
    }

    private mutating func stopCurrentBlock() async throws {
        guard let block = currentBlock else {
            return
        }
        if block.kind == .thinking {
            try await writer.sendSSE(
                event: "content_block_delta",
                data: AnthropicContentBlockDelta(index: block.index, delta: .signature(""))
            )
        }
        try await writer.sendSSE(
            event: "content_block_stop",
            data: AnthropicIndexedEvent(type: "content_block_stop", index: block.index)
        )
        currentBlock = nil
    }

    private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.mlxServer.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

struct AnthropicStreamBlock: Equatable {
    var kind: AnthropicContentFragment.Kind
    var index = -1

    init(kind: AnthropicContentFragment.Kind) {
        self.kind = kind
    }
}

struct AnthropicContentFragment: Equatable {
    enum Kind: Equatable {
        case text
        case thinking
    }

    var kind: Kind
    var text: String
}

struct AnthropicThinkingSplitter {
    private enum Mode {
        case text
        case thinking
        case discardingThinking
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private let emitsThinking: Bool
    private var mode: Mode
    private var buffer = ""

    init(emitsThinking: Bool, startsInThinking: Bool) {
        self.emitsThinking = emitsThinking
        mode = startsInThinking
            ? (emitsThinking ? .thinking : .discardingThinking)
            : .text
    }

    mutating func consume(_ chunk: String) -> [AnthropicContentFragment] {
        buffer += chunk
        return drain(flush: false)
    }

    mutating func finish() -> [AnthropicContentFragment] {
        drain(flush: true)
    }

    static func collect(
        _ text: String,
        emitsThinking: Bool,
        startsInThinking: Bool
    ) -> [AnthropicContentFragment] {
        if startsInThinking,
           text.range(of: Self.closeTag) == nil {
            return text.isEmpty ? [] : [.init(kind: .text, text: text)]
        }

        var splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: startsInThinking
        )
        var fragments = splitter.consume(text)
        fragments.append(contentsOf: splitter.finish())
        return fragments
    }

    private mutating func drain(flush: Bool) -> [AnthropicContentFragment] {
        var fragments: [AnthropicContentFragment] = []

        while !buffer.isEmpty {
            switch mode {
            case .text:
                if let closeRange = firstRange(of: Self.closeTag),
                   range(Self.openTag, occursAfter: closeRange) || firstRange(of: Self.openTag) == nil {
                    buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                    continue
                }

                if let openRange = firstRange(of: Self.openTag) {
                    appendText(
                        String(buffer[..<openRange.lowerBound]),
                        kind: .text,
                        to: &fragments
                    )
                    buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                    mode = emitsThinking ? .thinking : .discardingThinking
                    continue
                }

                let text = consumableText(flush: flush, tags: [Self.openTag, Self.closeTag])
                guard !text.isEmpty else {
                    break
                }
                appendText(text, kind: .text, to: &fragments)
                buffer.removeFirst(text.count)

            case .thinking, .discardingThinking:
                if let openRange = firstRange(of: Self.openTag),
                   openRange.lowerBound == buffer.startIndex {
                    buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                    continue
                }

                if let closeRange = firstRange(of: Self.closeTag) {
                    if mode == .thinking {
                        appendText(
                            String(buffer[..<closeRange.lowerBound]),
                            kind: .thinking,
                            to: &fragments
                        )
                    }
                    buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                    mode = .text
                    continue
                }

                let text = consumableText(flush: flush, tags: [Self.openTag, Self.closeTag])
                guard !text.isEmpty else {
                    break
                }
                if mode == .thinking {
                    appendText(text, kind: .thinking, to: &fragments)
                }
                buffer.removeFirst(text.count)
            }
        }

        return fragments
    }

    private mutating func appendText(
        _ text: String,
        kind: AnthropicContentFragment.Kind,
        to fragments: inout [AnthropicContentFragment]
    ) {
        guard !text.isEmpty else {
            return
        }
        if fragments.last?.kind == kind {
            fragments[fragments.count - 1].text += text
        } else {
            fragments.append(.init(kind: kind, text: text))
        }
    }

    private func firstRange(of tag: String) -> Range<String.Index>? {
        buffer.range(of: tag)
    }

    private func range(_ tag: String, occursAfter other: Range<String.Index>) -> Bool {
        guard let range = firstRange(of: tag) else {
            return true
        }
        return range.lowerBound > other.lowerBound
    }

    private func consumableText(flush: Bool, tags: [String]) -> String {
        if flush {
            return buffer
        }

        let retained = retainedTagPrefixLength(tags: tags)
        guard retained > 0 else {
            return buffer
        }
        return String(buffer.dropLast(retained))
    }

    private func retainedTagPrefixLength(tags: [String]) -> Int {
        var best = 0
        for tag in tags {
            let maxLength = min(buffer.count, tag.count - 1)
            guard maxLength > 0 else {
                continue
            }
            for length in 1...maxLength {
                if buffer.hasSuffix(String(tag.prefix(length))) {
                    best = max(best, length)
                }
            }
        }
        return best
    }
}

enum AnthropicToolUseID {
    static func make() -> String {
        "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

struct AnthropicMessageResponse: Encodable {
    var id = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    var type = "message"
    var role = "assistant"
    var model: String
    var content: [AnthropicResponseContent]
    var stopReason: String
    var stopSequence: String?
    var usage: AnthropicUsage
    var mlxMetrics: MLXMetrics?

    init(
        model: String,
        text: String,
        toolCalls: [ToolCall],
        emitsThinking: Bool,
        info: GenerateCompletionInfo?
    ) {
        self.model = model
        content = AnthropicThinkingSplitter.collect(
            text,
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        ).map { fragment in
            switch fragment.kind {
            case .text:
                .text(fragment.text)
            case .thinking:
                .thinking(fragment.text)
            }
        }
        content.append(
            contentsOf: toolCalls.map { toolCall in
                .toolUse(
                    id: AnthropicToolUseID.make(),
                    name: toolCall.function.name,
                    input: toolCall.function.arguments
                )
            }
        )
        stopReason = toolCalls.isEmpty ? "end_turn" : "tool_use"
        usage = AnthropicUsage(info: info)
        mlxMetrics = info.map(MLXMetrics.init)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case model
        case content
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
        case mlxMetrics = "mlx_metrics"
    }

}

enum AnthropicResponseContent: Encodable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case signature
        case id
        case name
        case input
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
            try container.encode("", forKey: .signature)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        }
    }
}

struct AnthropicMessageStart: Encodable {
    var type = "message_start"
    var message: Message

    init(id: String, model: String) {
        message = Message(id: id, model: model)
    }

    struct Message: Encodable {
        var id: String
        var type = "message"
        var role = "assistant"
        var model: String
        var content: [String] = []
        var stopReason: String?
        var stopSequence: String?
        var usage = AnthropicUsage(inputTokens: 0, outputTokens: 0)

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case role
            case model
            case content
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
            case usage
        }
    }
}

struct AnthropicContentBlockStart: Encodable {
    var type = "content_block_start"
    var index: Int
    var contentBlock: AnthropicContentBlock

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case contentBlock = "content_block"
    }
}

enum AnthropicContentBlock: Encodable {
    case text
    case thinking
    case toolUse(id: String, name: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case signature
        case id
        case name
        case input
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text:
            try container.encode("text", forKey: .type)
            try container.encode("", forKey: .text)
        case .thinking:
            try container.encode("thinking", forKey: .type)
            try container.encode("", forKey: .thinking)
            try container.encode("", forKey: .signature)
        case .toolUse(let id, let name):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode([String: JSONValue](), forKey: .input)
        }
    }
}

struct AnthropicContentBlockDelta: Encodable {
    var type = "content_block_delta"
    var index: Int
    var delta: AnthropicContentDelta

}

enum AnthropicContentDelta: Encodable {
    case text(String)
    case thinking(String)
    case inputJSON(String)
    case signature(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case partialJSON = "partial_json"
        case signature
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text_delta", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking):
            try container.encode("thinking_delta", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
        case .inputJSON(let partialJSON):
            try container.encode("input_json_delta", forKey: .type)
            try container.encode(partialJSON, forKey: .partialJSON)
        case .signature(let signature):
            try container.encode("signature_delta", forKey: .type)
            try container.encode(signature, forKey: .signature)
        }
    }
}

struct AnthropicMessageDelta: Encodable {
    var type = "message_delta"
    var delta: Delta
    var usage = AnthropicUsage(inputTokens: 0, outputTokens: 0)

    init(stopReason: String) {
        delta = Delta(stopReason: stopReason, stopSequence: nil)
    }

    struct Delta: Encodable {
        var stopReason: String
        var stopSequence: String?

        enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
        }
    }
}

struct AnthropicIndexedEvent: Encodable {
    var type: String
    var index: Int = 0
}

struct AnthropicTypedEvent: Encodable {
    var type: String
}
