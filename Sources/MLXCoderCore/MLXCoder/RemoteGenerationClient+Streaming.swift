//
//  Split from RemoteGenerationClient.swift
//  MLXCoder
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension RemoteGenerationClient {
    public func validateConfiguration() throws {
        guard URL(string: provider.baseURL) != nil else {
            throw RemoteGenerationClientError.invalidBaseURL(provider.baseURL)
        }
        if provider.requiresAPIKey, apiKey == nil {
            throw RemoteGenerationClientError.missingAPIKey(provider.displayTitle)
        }
    }

    public func applyThinkingSelection(
        _ thinkingSelection: AgentThinkingSelection?,
        to body: inout [String: Any]
    ) {
        guard let thinkingSelection else {
            return
        }
        switch thinkingPayloadStyle {
        case .openRouterReasoning:
            body["reasoning"] = thinkingSelection.openRouterReasoningPayload
        case .chatTemplateKwargs:
            var kwargs: [String: Any] = [
                "enable_thinking": thinkingSelection.isEnabled,
                "thinking": thinkingSelection.isEnabled
            ]
            if let reasoningEffort = thinkingSelection.chatTemplateReasoningEffort {
                kwargs["reasoning_effort"] = reasoningEffort
            }
            body["chat_template_kwargs"] = kwargs
        }
    }

    public var thinkingPayloadStyle: AgentThinkingPayloadStyle {
        if AgentRemoteProvider.isModalDirectBaseURL(provider.baseURL)
            || AgentRemoteProvider.isNVIDIABaseURL(provider.baseURL) {
            return .chatTemplateKwargs
        }
        return .openRouterReasoning
    }

    public func streamChatCompletions(
        messages: [[String: Any]],
        sessionID: String,
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL? = nil,
        thinkingSelection: AgentThinkingSelection?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(Self.toolExposureDiagnostic(from: toolDescriptors)))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        var body: [String: Any] = [
            "model": provider.modelID,
            "messages": toolCatalog.wireMessages(from: messages),
            "stream": true,
            "stream_options": [
                "include_usage": true
            ]
        ]
        applyThinkingSelection(thinkingSelection, to: &body)
        if provider.chatEndpoint.usesSessionID {
            body["session_id"] = sessionID
        }
        let toolPayloads = toolCatalog.chatCompletionToolPayloads
        if !toolPayloads.isEmpty {
            body["tools"] = toolPayloads
            body["tool_choice"] = "auto"
        }
        if let maxTokens = configuration.maxOutputTokens {
            body["max_tokens"] = maxTokens
        }

        let result = try await streamRequest(
            path: provider.chatEndpoint.path,
            body: body,
            onEvent: onEvent,
            eventParser: Self.parseChatCompletionStreamEvent
        )
        return RemoteStreamResult(
            text: result.text,
            stopReason: result.stopReason,
            toolCalls: result.toolCalls.map(toolCatalog.localToolCall),
            stats: result.stats
        )
    }

    public func streamResponses(
        messages: [[String: Any]],
        sessionID: String,
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL? = nil,
        thinkingSelection: AgentThinkingSelection?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(Self.toolExposureDiagnostic(from: toolDescriptors)))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        let normalizedInput = Self.responsesInputPayload(
            from: toolCatalog.wireMessages(from: messages)
        )
        var body: [String: Any] = [
            "model": provider.modelID,
            "input": normalizedInput.input,
            "stream": true,
            "stream_options": [
                "include_usage": true
            ]
        ]
        if let instructions = normalizedInput.instructions {
            body["instructions"] = instructions
        }
        applyThinkingSelection(thinkingSelection, to: &body)
        if provider.chatEndpoint.usesSessionID {
            body["session_id"] = sessionID
        }
        let toolPayloads = toolCatalog.responsesToolPayloads
        if !toolPayloads.isEmpty {
            body["tools"] = toolPayloads
            body["tool_choice"] = "auto"
        }
        if let maxTokens = configuration.maxOutputTokens {
            body["max_output_tokens"] = maxTokens
        }

        let result = try await streamRequest(
            path: provider.chatEndpoint.path,
            body: body,
            onEvent: onEvent,
            eventParser: Self.parseResponsesStreamEvent
        )
        return RemoteStreamResult(
            text: result.text,
            stopReason: result.stopReason,
            toolCalls: result.toolCalls.map(toolCatalog.localToolCall),
            stats: result.stats
        )
    }

    public func streamRequest(
        path: String,
        body: [String: Any],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void,
        eventParser: @escaping ([String: Any]) -> [ParsedRemoteStreamEvent]
    ) async throws -> RemoteStreamResult {
        var request = URLRequest(url: try endpointURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONValue(jsonObject: body).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )

        if !configuration.appMode {
            await onEvent(.diagnostic("Remote request: \(provider.displayTitle) \(provider.modelID)."))
        }
        let requestStartedAt = Date()
        let (bytes, response) = try await urlSession.bytes(for: request)
        try validateHTTPResponse(response)

        var accumulatedText = ""
        var stopReason = "end_turn"
        var toolCallAccumulator = RemoteToolCallAccumulator()
        var firstDeltaAt: Date?
        var usage: RemoteGenerationUsage?
        var contentNormalizer = ThinkingBoundarySpacingNormalizer()

        func markFirstDelta() {
            if firstDeltaAt == nil {
                firstDeltaAt = Date()
            }
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = Self.ssePayload(from: line) else {
                continue
            }
            if payload == "[DONE]" {
                break
            }
            guard let object = Self.jsonObject(from: payload) else {
                continue
            }

            for event in eventParser(object) {
                switch event {
                case let .content(delta):
                    guard !delta.isEmpty else {
                        continue
                    }
                    markFirstDelta()
                    let normalizedDelta = contentNormalizer.append(delta)
                    guard !normalizedDelta.isEmpty else {
                        continue
                    }
                    accumulatedText.append(normalizedDelta)
                    await onEvent(.content(normalizedDelta))
                case let .contentSnapshot(snapshot):
                    let delta = Self.streamContentDelta(
                        fromSnapshot: snapshot,
                        accumulatedText: accumulatedText
                    )
                    guard !delta.isEmpty else {
                        continue
                    }
                    markFirstDelta()
                    let normalizedDelta = contentNormalizer.append(delta)
                    guard !normalizedDelta.isEmpty else {
                        continue
                    }
                    accumulatedText.append(normalizedDelta)
                    await onEvent(.content(normalizedDelta))
                case let .reasoning(delta):
                    guard !delta.isEmpty else {
                        continue
                    }
                    markFirstDelta()
                    await onEvent(.thought(delta))
                case let .toolCallDelta(rawToolCalls):
                    markFirstDelta()
                    toolCallAccumulator.ingestChatCompletionToolCalls(rawToolCalls)
                case let .responseToolCallItem(item, outputIndex):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallItem(
                        item,
                        outputIndex: outputIndex
                    )
                case let .responseToolCallArgumentsDelta(event):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallArgumentsDelta(event)
                case let .responseToolCallArgumentsDone(event):
                    markFirstDelta()
                    toolCallAccumulator.ingestResponseToolCallArgumentsDone(event)
                case let .stop(reason):
                    stopReason = reason
                case let .failure(message):
                    throw RemoteGenerationClientError.remoteFailure(message)
                case let .usage(remoteUsage):
                    usage = remoteUsage
                case .ignored:
                    continue
                }
            }
        }
        let normalizedRemainder = contentNormalizer.finish()
        if !normalizedRemainder.isEmpty {
            markFirstDelta()
            accumulatedText.append(normalizedRemainder)
            await onEvent(.content(normalizedRemainder))
        }

        let toolCalls = try toolCallAccumulator.finalize()
        return RemoteStreamResult(
            text: accumulatedText,
            stopReason: toolCalls.isEmpty ? stopReason : "tool_calls",
            toolCalls: toolCalls,
            stats: RemoteGenerationStats(
                usage: usage,
                requestStartedAt: requestStartedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: Date(),
                generatedCharacterCount: accumulatedText.count
            )
        )
    }

    public static func toolExposureDiagnostic(from descriptors: [DirectToolDescriptor]) -> String {
        let names = descriptors.map(\.name).filter { !$0.isEmpty }.sorted()
        let sample = names.prefix(8).joined(separator: ",")
        let suffix = names.count > 8 ? ",..." : ""
        return "Remote tools exposed: \(names.count)[\(sample)\(suffix)]"
    }

    public func endpointURL(path: String) throws -> URL {
        guard var url = URL(string: provider.baseURL) else {
            throw RemoteGenerationClientError.invalidBaseURL(provider.baseURL)
        }
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    public func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RemoteGenerationClientError.httpStatus(httpResponse.statusCode)
        }
    }

    public static func ssePayload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else {
            return nil
        }
        return String(trimmed.dropFirst("data:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func jsonObject(from payload: String) -> [String: Any]? {
        guard let data = payload.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.mlxObjectValue else {
            return nil
        }
        return object.mapValues(\.jsonObject)
    }

    private static func chatCompletionToolPayloads(
        from descriptors: [DirectToolDescriptor]
    ) -> [[String: Any]] {
        descriptors.compactMap { descriptor in
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.description,
                    "parameters": schema
                ]
            ]
        }
    }

    private static func responsesToolPayloads(
        from descriptors: [DirectToolDescriptor]
    ) -> [[String: Any]] {
        descriptors.compactMap { descriptor in
            guard let schema = descriptor.schemaObject else {
                return nil
            }
            return [
                "type": "function",
                "name": descriptor.name,
                "description": descriptor.description,
                "parameters": schema
            ]
        }
    }

    public static func parseChatCompletionStreamEvent(
        _ object: [String: Any]
    ) -> [ParsedRemoteStreamEvent] {
        var events = usageEvents(from: object)
        guard let choice = (object["choices"] as? [[String: Any]])?.first else {
            return events.isEmpty ? [.ignored] : events
        }
        if let reason = choice["finish_reason"] as? String,
           !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(.stop(reason))
        }
        if let delta = choice["delta"] as? [String: Any] {
            if let content = Self.streamContentText(from: delta["content"]) {
                events.append(.content(content))
            }
            if let reasoning = delta["reasoning"] as? String {
                events.append(.reasoning(reasoning))
            }
            if let reasoning = delta["reasoning_content"] as? String {
                events.append(.reasoning(reasoning))
            }
            if let rawToolCalls = delta["tool_calls"] as? [[String: Any]] {
                events.append(.toolCallDelta(rawToolCalls))
            }
        }
        if let message = choice["message"] as? [String: Any],
           let rawToolCalls = message["tool_calls"] as? [[String: Any]] {
            events.append(.toolCallDelta(rawToolCalls))
        }
        return events.isEmpty ? [.ignored] : events
    }

    public static func parseResponsesStreamEvent(
        _ object: [String: Any]
    ) -> [ParsedRemoteStreamEvent] {
        var usageEvents = usageEvents(from: object)
        guard let type = object["type"] as? String else {
            return usageEvents.isEmpty ? [.ignored] : usageEvents
        }
        switch type {
        case "response.output_text.delta":
            usageEvents.append(.content(object["delta"] as? String ?? ""))
            return usageEvents
        case "response.content_part.delta":
            if let delta = Self.responseContentPartDelta(from: object) {
                usageEvents.append(.content(delta))
            }
            return usageEvents
        case "response.content_part.done":
            if let part = object["part"] as? [String: Any],
               let text = Self.responseContentPartText(from: part) {
                usageEvents.append(.contentSnapshot(text))
            }
            return usageEvents
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            usageEvents.append(.reasoning(object["delta"] as? String ?? ""))
            return usageEvents
        case "response.output_item.added", "response.output_item.done":
            var events = usageEvents
            if let item = object["item"] as? [String: Any] {
                if Self.isResponseToolCallItem(item) {
                    events.append(
                        .responseToolCallItem(
                            item,
                            outputIndex: Self.integerValue(object["output_index"])
                        )
                    )
                } else if type == "response.output_item.done",
                          let text = Self.responseOutputText(from: item)?.nilIfBlank {
                    events.append(.contentSnapshot(text))
                }
            }
            return events.isEmpty ? [.ignored] : events
        case "response.function_call_arguments.delta":
            usageEvents.append(.responseToolCallArgumentsDelta(object))
            return usageEvents
        case "response.function_call_arguments.done":
            usageEvents.append(.responseToolCallArgumentsDone(object))
            return usageEvents
        case "response.completed", "response.done":
            var events = usageEvents
            if let response = object["response"] as? [String: Any],
               let outputItems = response["output"] as? [[String: Any]] {
                for (index, item) in outputItems.enumerated() {
                    if Self.isResponseToolCallItem(item) {
                        events.append(.responseToolCallItem(item, outputIndex: index))
                    }
                }
            }
            events.append(.stop("end_turn"))
            return events
        case "response.failed", "response.incomplete":
            usageEvents.append(.failure(responseFailureMessage(from: object, fallbackType: type)))
            return usageEvents
        default:
            return usageEvents.isEmpty ? [.ignored] : usageEvents
        }
    }

    static func streamContentDelta(
        fromSnapshot snapshot: String,
        accumulatedText: String
    ) -> String {
        guard !snapshot.isEmpty, !accumulatedText.isEmpty else {
            return snapshot
        }
        if snapshot == accumulatedText {
            return ""
        }
        if snapshot.hasPrefix(accumulatedText) {
            return String(snapshot.dropFirst(accumulatedText.count))
        }
        return snapshot
    }

    private static func responseContentPartDelta(from object: [String: Any]) -> String? {
        if let delta = responseContentPartText(from: object["delta"]) {
            return delta
        }
        return responseContentPartText(from: object)
    }

    private static func responseContentPartText(from value: Any?) -> String? {
        if let text = streamContentText(from: value)?.nilIfBlank {
            return text
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        let type = stringValue(object["type"])?.lowercased() ?? ""
        guard !type.contains("reasoning") else {
            return nil
        }
        return streamContentText(from: object["text"])?.nilIfBlank
            ?? streamContentText(from: object["content"])?.nilIfBlank
            ?? streamContentText(from: object["delta"])?.nilIfBlank
    }

    private static func streamContentText(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let items = value as? [[String: Any]] {
            let text = items
                .compactMap { item -> String? in
                    if let text = item["text"] as? String {
                        return text
                    }
                    return item["content"] as? String
                }
                .joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    public static func responseFailureMessage(
        from object: [String: Any],
        fallbackType: String
    ) -> String {
        if let response = object["response"] as? [String: Any],
           let message = responseErrorMessage(from: response["error"]) {
            return message
        }
        if let message = responseErrorMessage(from: object["error"]) {
            return message
        }
        return fallbackType
    }

    public static func responseErrorMessage(from value: Any?) -> String? {
        if let string = value as? String {
            return string.nilIfBlank
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        return stringValue(object["message"])?.nilIfBlank
            ?? stringValue(object["metadata"])?.nilIfBlank
            ?? stringValue(object["code"])?.nilIfBlank
            ?? stringValue(object["type"])?.nilIfBlank
    }
}
