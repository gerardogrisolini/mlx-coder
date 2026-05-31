//
//  MLXServerHTTPEndToEndTests.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore
import MLXServerHTTP
import Testing

@Test
func modelsEndpointIncludesThinkingParameters() async throws {
    let runtime = RecordingRuntime(outputText: "ok")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let data = try await server.get(path: "/v1/models")
    let response = try JSONDecoder().decode(ModelsTestResponse.self, from: data)
    let model = try #require(response.data.first)
    let thinking = try #require(model.thinking)

    #expect(model.id == "mlx-community/test-model")
    #expect(thinking.supportsThinking)
    #expect(thinking.supportsReasoningEffort)
    #expect(thinking.supportsPreserveThinking)
    #expect(thinking.availableSelections == ["off", "low", "medium", "high"])
    #expect(thinking.defaultSelection == "medium")
}

@Test
func chatCompletionsEndpointMapsThinkingProtocol() async throws {
    let runtime = RecordingRuntime(outputText: "<think>Sto ragionando.</think>Ciao!")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "messages": [
        { "role": "user", "content": "ciao" }
      ],
      "reasoning_effort": "medium",
      "max_tokens": 64
    }
    """

    let data = try await server.post(path: "/v1/chat/completions", body: body)
    let response = try JSONDecoder().decode(ChatCompletionTestResponse.self, from: data)
    let message = try #require(response.choices.first?.message)
    let request = try await #require(runtime.lastRequest)

    #expect(response.model == "mlx-community/test-model")
    #expect(message.content == "Ciao!")
    #expect(message.reasoningContent == "Sto ragionando.")
    #expect(request.messages.map(\.role) == [.user])
    #expect(request.messages.map(\.content) == ["ciao"])
    #expect(request.additionalContext?["enable_thinking"] as? Bool == true)
    #expect(request.additionalContext?["thinking_level"] as? String == "medium")
}

@Test
func responsesEndpointMapsReasoningProtocol() async throws {
    let runtime = RecordingRuntime(outputText: "<think>Analisi breve.</think>Risposta finale.")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "input": "ciao",
      "reasoning": {
        "effort": "high",
        "summary": "auto"
      },
      "max_output_tokens": 64
    }
    """

    let data = try await server.post(path: "/v1/responses", body: body)
    let responseText = String(decoding: data, as: UTF8.self)
    let response = try JSONDecoder().decode(ResponsesTestResponse.self, from: data)
    let reasoning = try #require(response.output.first { $0.type == "reasoning" })
    let message = try #require(response.output.first { $0.type == "message" })
    let request = try await #require(runtime.lastRequest)

    #expect(response.model == "mlx-community/test-model")
    #expect(reasoning.summary?.first?.text == "Analisi breve.")
    #expect(message.content?.first?.text == "Risposta finale.")
    #expect(responseText.contains(#""input_tokens""#))
    #expect(responseText.contains(#""output_tokens""#))
    #expect(request.messages.map(\.role) == [.user])
    #expect(request.messages.map(\.content) == ["ciao"])
    #expect(request.additionalContext?["enable_thinking"] as? Bool == true)
    #expect(request.additionalContext?["thinking_level"] as? String == "high")
}

@Test
func responsesEndpointMovesDeveloperMessagesToSystemPrefix() async throws {
    let runtime = RecordingRuntime(outputText: "Ok.")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "instructions": "Base instructions.",
      "input": [
        {
          "type": "message",
          "role": "user",
          "content": "ciao"
        },
        {
          "type": "message",
          "role": "developer",
          "content": "Developer rules."
        },
        {
          "type": "message",
          "role": "user",
          "content": "come va?"
        }
      ]
    }
    """

    _ = try await server.post(path: "/v1/responses", body: body)
    let request = try await #require(runtime.lastRequest)

    #expect(request.messages.map(\.role) == [.system, .user, .user])
    #expect(request.messages.map(\.content) == [
        "Base instructions.\n\nDeveloper rules.",
        "ciao",
        "come va?"
    ])
}

@Test
func anthropicMessagesEndpointMapsThinkingProtocol() async throws {
    let runtime = RecordingRuntime(outputText: "<think>Controllo il contesto.</think>Eccomi.")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "max_tokens": 64,
      "messages": [
        { "role": "user", "content": "dove sei?" }
      ],
      "thinking": {
        "type": "enabled"
      }
    }
    """

    let data = try await server.post(path: "/v1/messages", body: body)
    let response = try JSONDecoder().decode(AnthropicMessageTestResponse.self, from: data)
    let thinking = try #require(response.content.first { $0.type == "thinking" })
    let text = try #require(response.content.first { $0.type == "text" })
    let request = try await #require(runtime.lastRequest)

    #expect(response.model == "mlx-community/test-model")
    #expect(thinking.thinking == "Controllo il contesto.")
    #expect(text.text == "Eccomi.")
    #expect(request.messages.map(\.role) == [.user])
    #expect(request.messages.map(\.content) == ["dove sei?"])
    #expect(request.additionalContext?["enable_thinking"] as? Bool == true)
    #expect(request.additionalContext?["thinking_level"] as? String == "medium")
}

@Test
func anthropicMessagesEndpointFiltersBillingHeaderFromSystemPrompt() async throws {
    let runtime = RecordingRuntime(outputText: "Ciao.")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "max_tokens": 64,
      "system": [
        { "type": "text", "text": "Sei un assistente utile." },
        { "type": "text", "text": "x-anthropic-billing-header: volatile-value" }
      ],
      "messages": [
        { "role": "user", "content": "ciao" }
      ]
    }
    """

    _ = try await server.post(path: "/v1/messages", body: body)
    let request = try await #require(runtime.lastRequest)

    #expect(request.messages.map(\.role) == [.system, .user])
    #expect(request.messages.first?.content == "Sei un assistente utile.")
}

@Test
func anthropicMessagesEndpointMapsPreviousAssistantThinkingAndToolUse() async throws {
    let runtime = RecordingRuntime(outputText: "Continuo.")
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "max_tokens": 64,
      "messages": [
        { "role": "user", "content": "prima" },
        {
          "role": "assistant",
          "content": [
            { "type": "thinking", "thinking": "Analizzo." },
            { "type": "text", "text": "Risposta." },
            {
              "type": "tool_use",
              "id": "toolu_test",
              "name": "lookup",
              "input": { "city": "Roma" }
            }
          ]
        },
        { "role": "user", "content": "continua" }
      ],
      "thinking": {
        "type": "enabled"
      }
    }
    """

    _ = try await server.post(path: "/v1/messages", body: body)
    let request = try await #require(runtime.lastRequest)

    #expect(request.messages.map(\.role) == [.user, .assistant, .assistant, .user])
    #expect(
        request.messages.map(\.content) == [
            "prima",
            "reasoning_summary:\nAnalizzo.",
            "Risposta.",
            "continua"
        ]
    )
    #expect(request.messages[2].toolCalls.map(\.function.name) == ["lookup"])
    #expect(request.messages[2].toolCalls.first?.id == "toolu_test")
    #expect(request.retainsReasoningInHistory)
}

@Test
func chatCompletionsStreamingEmitsThinkingTextAndToolCalls() async throws {
    let runtime = RecordingRuntime(
        streamEvents: [
            .chunk("<think>Sto ragionando.</think>"),
            .chunk("Ciao!"),
            .toolCall(testToolCall())
        ]
    )
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "stream": true,
      "messages": [
        { "role": "user", "content": "ciao" }
      ],
      "reasoning_effort": "medium",
      "tools": [
        {
          "type": "function",
          "function": {
            "name": "lookup",
            "parameters": { "type": "object" }
          }
        }
      ]
    }
    """

    let frames = try await server.postSSE(path: "/v1/chat/completions", body: body)
    let dataFrames = frames.map(\.data)

    #expect(dataFrames.contains { $0.contains(#""reasoning_content":"Sto ragionando.""#) })
    #expect(dataFrames.contains { $0.contains(#""content":"Ciao!""#) })
    #expect(dataFrames.contains { $0.contains(#""tool_calls""#) && $0.contains(#""name":"lookup""#) })
    #expect(dataFrames.contains { $0.contains(#""finish_reason":"tool_calls""#) })
    #expect(dataFrames.last == "[DONE]")
}

@Test
func responsesStreamingEmitsThinkingTextAndToolCalls() async throws {
    let runtime = RecordingRuntime(
        streamEvents: [
            .chunk("<think>Analisi.</think>"),
            .chunk("Risposta."),
            .toolCall(testToolCall())
        ]
    )
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "stream": true,
      "input": "ciao",
      "reasoning": {
        "effort": "high",
        "summary": "auto"
      },
      "tools": [
        {
          "type": "function",
          "name": "lookup",
          "parameters": { "type": "object" }
        }
      ]
    }
    """

    let frames = try await server.postSSE(path: "/v1/responses", body: body)

    #expect(frames.contains { $0.event == "response.reasoning_summary_text.delta" && $0.data.contains(#""delta":"Analisi.""#) })
    #expect(frames.contains { $0.event == "response.output_text.delta" && $0.data.contains(#""delta":"Risposta.""#) })
    #expect(frames.contains { $0.event == "response.function_call_arguments.delta" && $0.data.contains(#"{\"city\":\"Roma\"}"#) })
    #expect(frames.contains { $0.event == "response.output_item.done" && $0.data.contains(#""type":"function_call""#) && $0.data.contains(#""name":"lookup""#) })
    #expect(frames.contains { $0.event == "response.completed" })
}

@Test
func anthropicMessagesStreamingEmitsThinkingTextAndToolCalls() async throws {
    let runtime = RecordingRuntime(
        streamEvents: [
            .chunk("<think>Controllo.</think>"),
            .chunk("Eccomi."),
            .toolCall(testToolCall())
        ]
    )
    let server = try TestHTTPServer(runtime: runtime)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "stream": true,
      "max_tokens": 64,
      "messages": [
        { "role": "user", "content": "dove sei?" }
      ],
      "thinking": {
        "type": "enabled"
      },
      "tools": [
        {
          "name": "lookup",
          "input_schema": { "type": "object" }
        }
      ]
    }
    """

    let frames = try await server.postSSE(path: "/v1/messages", body: body)

    #expect(frames.contains { $0.event == "content_block_start" && $0.data.contains(#""type":"thinking""#) })
    #expect(frames.contains { $0.event == "content_block_delta" && $0.data.contains(#""thinking":"Controllo.""#) })
    #expect(frames.contains { $0.event == "content_block_start" && $0.data.contains(#""type":"text""#) })
    #expect(frames.contains { $0.event == "content_block_delta" && $0.data.contains(#""text":"Eccomi.""#) })
    #expect(frames.contains { $0.event == "content_block_start" && $0.data.contains(#""type":"tool_use""#) && $0.data.contains(#""name":"lookup""#) })
    #expect(frames.contains { $0.event == "content_block_delta" && $0.data.contains(#""partial_json":"{\"city\":\"Roma\"}""#) })
    #expect(frames.contains { $0.event == "message_delta" && $0.data.contains(#""stop_reason":"tool_use""#) })
    #expect(frames.contains { $0.event == "message_stop" })
}

@Test
func metricsLoggerRecordsChatCacheDiagnostics() async throws {
    let metricsURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-metrics-\(UUID().uuidString).jsonl")
    defer {
        try? FileManager.default.removeItem(at: metricsURL)
    }
    let cacheEvent = MLXServerChatCacheEvent(
        status: .memoryHit,
        cachedSessionCount: 1,
        modelSessionCount: 1,
        priorTranscriptCount: 2,
        bestCommonPrefixCount: 2,
        bestCachedTranscriptCount: 2,
        bestModelCommonPrefixCount: 2,
        bestModelCachedTranscriptCount: 2,
        bestModelSameSystemSignature: true,
        bestModelSameToolsSignature: true,
        bestModelSameAdditionalContextSignature: true,
        bestModelSameMediaResizeSignature: true,
        bestModelSameReasoningRetention: true,
        cachedPromptTokenCount: 36
    )
    let runtime = RecordingRuntime(
        outputText: "CACHEDUE",
        completionInfo: GenerateCompletionInfo(
            promptTokenCount: 24,
            generationTokenCount: 3,
            promptTime: 0.1,
            generationTime: 0.03
        ),
        cacheEvent: cacheEvent
    )
    let logger = try MLXServerMetricsLogger(destination: .file(metricsURL))
    let server = try TestHTTPServer(runtime: runtime, metricsLogger: logger)
    defer {
        server.stop()
    }

    let body = """
    {
      "model": "mlx-community/test-model",
      "max_tokens": 8,
      "messages": [
        { "role": "user", "content": "ciao" }
      ]
    }
    """

    _ = try await server.post(path: "/v1/messages", body: body)
    var line: String?
    for _ in 0..<20 {
        line = try? String(contentsOf: metricsURL, encoding: .utf8)
            .split(separator: "\n")
            .last
            .map(String.init)
        if line != nil {
            break
        }
        try await Task.sleep(for: .milliseconds(25))
    }
    let data = try #require(line?.data(using: .utf8))
    let object = try #require(
        try JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(object["chat_cache_status"] as? String == "memory_hit")
    #expect(object["prompt_tokens"] as? Int == 60)
    #expect(object["prompt_tokens_processed"] as? Int == 24)
    #expect(object["prompt_tokens_cached"] as? Int == 36)
    #expect(object["total_tokens"] as? Int == 63)
    #expect(object["ttft_ms"] as? Double == 100)
    #expect(object["tpot_ms"] as? Double == 15)
    #expect((object["e2e_latency_s"] as? Double ?? 0) > 0)
    #expect((object["total_throughput_tokens_per_second"] as? Double ?? 0) > 0)
    #expect((object["processed_throughput_tokens_per_second"] as? Double ?? 0) > 0)
}

private actor RecordingRuntime: MLXServerRuntimeGenerating, MLXServerRuntimeCacheDiagnosing {
    private(set) var lastRequest: MLXServerGenerationRequest?
    private let outputText: String
    private let streamEvents: [RuntimeStreamEvent]?
    private let completionInfo: GenerateCompletionInfo?
    private var cacheEvent: MLXServerChatCacheEvent?

    init(outputText: String) {
        self.outputText = outputText
        streamEvents = nil
        completionInfo = nil
        cacheEvent = nil
    }

    init(
        outputText: String,
        completionInfo: GenerateCompletionInfo?,
        cacheEvent: MLXServerChatCacheEvent? = nil
    ) {
        self.outputText = outputText
        streamEvents = nil
        self.completionInfo = completionInfo
        self.cacheEvent = cacheEvent
    }

    init(streamEvents: [RuntimeStreamEvent]) {
        outputText = ""
        self.streamEvents = streamEvents
        completionInfo = nil
        cacheEvent = nil
    }

    func generateChatSession(
        request: MLXServerGenerationRequest
    ) async throws -> AsyncStream<Generation> {
        lastRequest = request
        if let streamEvents {
            return AsyncStream { continuation in
                for event in streamEvents {
                    continuation.yield(event.generation)
                }
                continuation.finish()
            }
        }
        let chunks = outputText.split(separator: " ", omittingEmptySubsequences: false)
        return AsyncStream { continuation in
            for (index, chunk) in chunks.enumerated() {
                let suffix = index == chunks.count - 1 ? "" : " "
                continuation.yield(.chunk("\(chunk)\(suffix)"))
            }
            continuation.finish()
        }
    }

    func generateChatSessionText(
        request: MLXServerGenerationRequest
    ) async throws -> MLXServerGenerationOutput {
        lastRequest = request
        return MLXServerGenerationOutput(text: outputText, info: completionInfo)
    }

    func consumeLastChatCacheEvent() async -> MLXServerChatCacheEvent? {
        defer {
            cacheEvent = nil
        }
        return cacheEvent
    }
}

private enum RuntimeStreamEvent: Sendable {
    case chunk(String)
    case toolCall(ToolCall)

    var generation: Generation {
        switch self {
        case .chunk(let chunk):
            .chunk(chunk)
        case .toolCall(let toolCall):
            .toolCall(toolCall)
        }
    }
}

private final class TestHTTPServer {
    private let server: MLXServerHTTPServer
    private let baseURL: URL

    init(runtime: RecordingRuntime, metricsLogger: MLXServerMetricsLogger? = nil) throws {
        let catalog = try MLXServerModelCatalog(
            manifest: MLXServerModelsManifest(
                defaultModelID: "mlx-community/test-model",
                models: [
                    MLXServerModelRecord(
                        id: "mlx-community/test-model",
                        displayName: "Test Model",
                        repositoryID: "mlx-community/test-model",
                        thinking: .effort(
                            levels: [.low, .medium, .high],
                            supportsPreserveThinking: true
                        )
                    )
                ]
            )
        )
        server = MLXServerHTTPServer(
            configuration: MLXServerConfiguration(host: "127.0.0.1", port: 0),
            runtime: runtime,
            modelCatalog: catalog,
            metricsLogger: metricsLogger
        )
        try server.start()
        let port = try #require(server.boundPort)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        try? server.stop()
    }

    func get(path: String) async throws -> Data {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        return data
    }

    func post(path: String, body: String) async throws -> Data {
        let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var request = URLRequest(url: baseURL.appendingPathComponent(normalizedPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)
        return data
    }

    func postSSE(path: String, body: String) async throws -> [SSEFrame] {
        let data = try await post(path: path, body: body)
        return SSEFrame.parse(String(decoding: data, as: UTF8.self))
    }
}

private struct ModelsTestResponse: Decodable {
    var data: [Model]

    struct Model: Decodable {
        var id: String
        var thinking: Thinking?
    }

    struct Thinking: Decodable {
        var supportsThinking: Bool
        var supportsReasoningEffort: Bool
        var supportsPreserveThinking: Bool
        var availableSelections: [String]
        var defaultSelection: String

        enum CodingKeys: String, CodingKey {
            case supportsThinking = "supports_thinking"
            case supportsReasoningEffort = "supports_reasoning_effort"
            case supportsPreserveThinking = "supports_preserve_thinking"
            case availableSelections = "available_selections"
            case defaultSelection = "default_selection"
        }
    }
}

private struct SSEFrame: Equatable {
    var event: String?
    var data: String

    static func parse(_ text: String) -> [SSEFrame] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        return normalized
            .components(separatedBy: "\n\n")
            .compactMap { rawFrame in
                var event: String?
                var dataLines: [String] = []
                for line in rawFrame.split(separator: "\n", omittingEmptySubsequences: false) {
                    if line.hasPrefix("event: ") {
                        event = String(line.dropFirst("event: ".count))
                    } else if line.hasPrefix("data: ") {
                        dataLines.append(String(line.dropFirst("data: ".count)))
                    }
                }
                guard !dataLines.isEmpty else {
                    return nil
                }
                return SSEFrame(event: event, data: dataLines.joined(separator: "\n"))
            }
    }
}

private func testToolCall() -> ToolCall {
    ToolCall(
        function: .init(
            name: "lookup",
            arguments: ["city": "Roma"]
        )
    )
}

private struct ChatCompletionTestResponse: Decodable {
    var model: String
    var choices: [Choice]

    struct Choice: Decodable {
        var message: Message
    }

    struct Message: Decodable {
        var content: String?
        var reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
        }
    }
}

private struct ResponsesTestResponse: Decodable {
    var model: String
    var output: [OutputItem]

    struct OutputItem: Decodable {
        var type: String
        var content: [ContentPart]?
        var summary: [ContentPart]?
    }

    struct ContentPart: Decodable {
        var text: String
    }
}

private struct AnthropicMessageTestResponse: Decodable {
    var model: String
    var content: [Content]

    struct Content: Decodable {
        var type: String
        var text: String?
        var thinking: String?
    }
}
