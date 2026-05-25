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
    let response = try JSONDecoder().decode(ResponsesTestResponse.self, from: data)
    let reasoning = try #require(response.output.first { $0.type == "reasoning" })
    let message = try #require(response.output.first { $0.type == "message" })
    let request = try await #require(runtime.lastRequest)

    #expect(response.model == "mlx-community/test-model")
    #expect(reasoning.summary?.first?.text == "Analisi breve.")
    #expect(message.content?.first?.text == "Risposta finale.")
    #expect(request.messages.map(\.role) == [.user])
    #expect(request.messages.map(\.content) == ["ciao"])
    #expect(request.additionalContext?["enable_thinking"] as? Bool == true)
    #expect(request.additionalContext?["thinking_level"] as? String == "high")
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

private actor RecordingRuntime: MLXServerRuntimeGenerating {
    private(set) var lastRequest: MLXServerGenerationRequest?
    private let outputText: String
    private let streamEvents: [RuntimeStreamEvent]?

    init(outputText: String) {
        self.outputText = outputText
        streamEvents = nil
    }

    init(streamEvents: [RuntimeStreamEvent]) {
        outputText = ""
        self.streamEvents = streamEvents
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
        return MLXServerGenerationOutput(text: outputText, info: nil)
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

    init(runtime: RecordingRuntime) throws {
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
            modelCatalog: catalog
        )
        try server.start()
        let port = try #require(server.boundPort)
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }

    func stop() {
        try? server.stop()
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
