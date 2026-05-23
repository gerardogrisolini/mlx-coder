//
//  Split from RemoteGenerationClient.swift
//  MLXCoder
//

import Foundation

public extension RemoteGenerationClient {
    public static func integerValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    public static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }

    public static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    public static func firstIntegerValue(
        in object: [String: Any],
        for keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = integerValue(object[key]) {
                return value
            }
        }
        return nil
    }

    public static func firstDoubleValue(
        in object: [String: Any],
        for keys: [String]
    ) -> Double? {
        for key in keys {
            if let value = doubleValue(object[key]) {
                return value
            }
        }
        return nil
    }

    public static func usageEvents(from object: [String: Any]) -> [ParsedRemoteStreamEvent] {
        var events: [ParsedRemoteStreamEvent] = []
        if let usageObject = object["usage"] as? [String: Any],
           let usage = parsedUsage(from: usageObject) {
            events.append(.usage(usage))
        }
        if let response = object["response"] as? [String: Any],
           let usageObject = response["usage"] as? [String: Any],
           let usage = parsedUsage(from: usageObject) {
            events.append(.usage(usage))
        }
        return events
    }

    public static func parsedUsage(
        from usageObject: [String: Any]
    ) -> RemoteGenerationUsage? {
        let inputTokens = integerValue(usageObject["input_tokens"])
            ?? integerValue(usageObject["inputTokens"])
        let anthropicCacheReadInputTokens =
            integerValue(usageObject["cache_read_input_tokens"])
            ?? integerValue(usageObject["cacheReadInputTokens"])
        let anthropicCacheCreationInputTokens =
            integerValue(usageObject["cache_creation_input_tokens"])
            ?? integerValue(usageObject["cacheCreationInputTokens"])
        let hasAnthropicCacheUsage =
            anthropicCacheReadInputTokens != nil
            || anthropicCacheCreationInputTokens != nil
        let promptTokens =
            integerValue(usageObject["prompt_tokens"])
            ?? integerValue(usageObject["total_input_tokens"])
            ?? integerValue(usageObject["promptTokens"])
            ?? integerValue(usageObject["totalInputTokens"])
            ?? {
                if hasAnthropicCacheUsage, let inputTokens {
                    return inputTokens
                        + (anthropicCacheReadInputTokens ?? 0)
                        + (anthropicCacheCreationInputTokens ?? 0)
                }
                return inputTokens
            }()
        let completionTokens =
            integerValue(usageObject["completion_tokens"])
            ?? integerValue(usageObject["output_tokens"])
            ?? integerValue(usageObject["completionTokens"])
            ?? integerValue(usageObject["outputTokens"])
        let totalTokens =
            integerValue(usageObject["total_tokens"])
            ?? integerValue(usageObject["totalTokens"])
            ?? {
                if let promptTokens, let completionTokens {
                    return promptTokens + completionTokens
                }
                return nil
            }()
        let contextTokens =
            integerValue(usageObject["context_tokens"])
            ?? integerValue(usageObject["context_window_tokens"])
            ?? integerValue(usageObject["active_context_tokens"])
            ?? integerValue(usageObject["contextTokens"])
            ?? integerValue(usageObject["contextWindowTokens"])
            ?? integerValue(usageObject["activeContextTokens"])
        let cachedPromptTokens =
            integerValue(usageObject["cached_prompt_tokens"])
            ?? integerValue(usageObject["cached_input_tokens"])
            ?? anthropicCacheReadInputTokens
            ?? integerValue(usageObject["prompt_tokens_cached"])
            ?? integerValue(usageObject["input_tokens_cached"])
            ?? integerValue(usageObject["cachedPromptTokens"])
            ?? integerValue(usageObject["cachedInputTokens"])
            ?? nestedIntegerValue(
                usageObject,
                objectKeys: ["prompt_tokens_details", "input_tokens_details"],
                valueKeys: ["cached_tokens", "cachedTokens"]
            )
        let explicitProcessedPromptTokens = firstIntegerValue(
            in: usageObject,
            for: [
                "processed_prompt_tokens",
                "processed_input_tokens",
                "prompt_tokens_processed",
                "input_tokens_processed",
                "promptProcessedTokens",
                "processedPromptTokens",
                "processedInputTokens",
                "inputProcessedTokens"
            ]
        )
        let nestedProcessedPromptTokens = nestedIntegerValue(
            usageObject,
            objectKeys: ["prompt_tokens_details", "input_tokens_details"],
            valueKeys: ["processed_tokens", "processedTokens"]
        )
        let anthropicProcessedPromptTokens = hasAnthropicCacheUsage ? inputTokens : nil
        let inferredProcessedPromptTokens: Int?
        if let promptTokens, let cachedPromptTokens {
            inferredProcessedPromptTokens = max(promptTokens - cachedPromptTokens, 0)
        } else {
            inferredProcessedPromptTokens = nil
        }
        let processedPromptTokens = explicitProcessedPromptTokens
            ?? nestedProcessedPromptTokens
            ?? anthropicProcessedPromptTokens
            ?? inferredProcessedPromptTokens
        let promptTokensPerSecond = firstDoubleValue(
            in: usageObject,
            for: [
                "prompt_tokens_per_second",
                "processed_prompt_tokens_per_second",
                "input_tokens_per_second",
                "promptTokensPerSecond",
                "processedPromptTokensPerSecond",
                "inputTokensPerSecond"
            ]
        )
        let completionTokensPerSecond = firstDoubleValue(
            in: usageObject,
            for: [
                "completion_tokens_per_second",
                "generation_tokens_per_second",
                "output_tokens_per_second",
                "tokens_per_second",
                "completionTokensPerSecond",
                "generationTokensPerSecond",
                "outputTokensPerSecond",
                "tokensPerSecond"
            ]
        )
        let responseDurationSeconds = firstDoubleValue(
            in: usageObject,
            for: [
                "response_duration_seconds",
                "responseDurationSeconds",
                "duration_seconds",
                "durationSeconds"
            ]
        )

        guard promptTokens != nil
                || completionTokens != nil
                || totalTokens != nil
                || contextTokens != nil
                || processedPromptTokens != nil
                || cachedPromptTokens != nil
                || promptTokensPerSecond != nil
                || completionTokensPerSecond != nil
                || responseDurationSeconds != nil else {
            return nil
        }

        return RemoteGenerationUsage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            contextTokens: contextTokens,
            processedPromptTokens: processedPromptTokens,
            cachedPromptTokens: cachedPromptTokens,
            promptTokensPerSecond: promptTokensPerSecond,
            completionTokensPerSecond: completionTokensPerSecond,
            responseDurationSeconds: responseDurationSeconds
        )
    }

    public static func nestedIntegerValue(
        _ object: [String: Any],
        objectKeys: [String],
        valueKeys: [String]
    ) -> Int? {
        for objectKey in objectKeys {
            guard let nested = object[objectKey] as? [String: Any] else {
                continue
            }
            for valueKey in valueKeys {
                if let value = integerValue(nested[valueKey]) {
                    return value
                }
            }
        }
        return nil
    }

    public static func generationSummary(
        _ stats: [RemoteGenerationStats],
        estimateMissingRates: Bool = false
    ) -> String? {
        guard let metrics = generationMetrics(
            stats,
            estimateMissingRates: estimateMissingRates
        ) else {
            return nil
        }

        let promptTime = stats.reduce(0) { $0 + $1.prefillElapsed }
        let generateTime = stats.reduce(0) { $0 + $1.generationElapsed }

        let renderedPromptTime = String(format: "%.2f", promptTime)
        let renderedGenerateTime = String(format: "%.2f", generateTime)
        var lines = ["Generation done:"]
        if stats.count > 1 {
            lines.append("  Rounds: \(stats.count)")
        }
        if let promptTokenCount = metrics.promptTokenCount {
            lines.append("  Prefill: \(promptTokenCount) tokens in \(renderedPromptTime)s")
        } else {
            lines.append("  Prefill: n/a in \(renderedPromptTime)s")
        }
        if let cachedPromptTokenCount = metrics.cachedPromptTokenCount,
           cachedPromptTokenCount > 0 {
            lines.append("  Cache: \(cachedPromptTokenCount) tokens reused")
        }
        if let promptTokensPerSecond = metrics.promptTokensPerSecond {
            lines.append(
                "  Prompt: \(String(format: "%.1f", promptTokensPerSecond)) tok/s"
            )
        } else {
            lines.append("  Prompt: n/a")
        }
        if let completionTokenCount = metrics.completionTokenCount {
            let speedSuffix = metrics.completionTokensPerSecond.map {
                " (\(String(format: "%.1f", $0)) tok/s)"
            } ?? ""
            lines.append(
                "  Output: \(completionTokenCount) tokens in \(renderedGenerateTime)s\(speedSuffix)"
            )
        } else {
            lines.append("  Output: n/a in \(renderedGenerateTime)s")
        }
        return lines.joined(separator: "\n")
    }

    public static func generationMetrics(
        _ stats: [RemoteGenerationStats],
        estimateMissingRates: Bool = false
    ) -> DirectAgentGenerationMetrics? {
        guard !stats.isEmpty else {
            return nil
        }

        let promptTokenCount = stats.compactMap {
            $0.usage?.processedPromptTokens ?? $0.usage?.promptTokens
        }.max()
        let cachedPromptTokenCount = stats.compactMap(\.usage?.cachedPromptTokens).max()
        let contextTokenCount = stats.compactMap(\.usage?.contextTokens).max()
        let completionTokenCount = summed(
            stats.compactMap(\.usage?.completionTokens)
        )
        let promptTokensPerSecond =
            average(stats.compactMap { stat in
                stat.usage?.promptTokensPerSecond
                    ?? rate(
                        tokens: stat.usage?.processedPromptTokens ?? stat.usage?.promptTokens,
                        seconds: stat.prefillElapsed,
                        enabled: estimateMissingRates
                    )
            })
        let completionTokensPerSecond =
            average(stats.compactMap { stat in
                stat.usage?.completionTokensPerSecond
                    ?? rate(
                        tokens: stat.usage?.completionTokens,
                        seconds: stat.generationElapsed,
                        enabled: estimateMissingRates
                    )
            })
        let responseDurationSeconds = stats.reduce(0) { partialResult, stat in
            partialResult
                + (stat.usage?.responseDurationSeconds
                    ?? stat.prefillElapsed + stat.generationElapsed)
        }

        return DirectAgentGenerationMetrics(
            promptTokenCount: promptTokenCount,
            cachedPromptTokenCount: cachedPromptTokenCount,
            promptTokensPerSecond: promptTokensPerSecond,
            completionTokenCount: completionTokenCount,
            completionTokensPerSecond: completionTokensPerSecond,
            responseDurationSeconds: responseDurationSeconds,
            contextTokenCount: contextTokenCount
        )
    }

    public static func publishGenerationMetrics(
        _ metrics: DirectAgentGenerationMetrics,
        maxTokens: Int?,
        modelID: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        await onEvent(.metrics(metrics))
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: metrics.totalTokenCount,
                    maxTokens: maxTokens,
                    modelID: modelID,
                    isApproximate: true
                )
            )
        )
    }

    public static func summed(_ values: [Int]) -> Int? {
        values.isEmpty ? nil : values.reduce(0, +)
    }

    public static func average(_ values: [Double]) -> Double? {
        let normalized = values.filter { $0.isFinite && $0 > 0 }
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized.reduce(0, +) / Double(normalized.count)
    }

    public static func rate(
        tokens: Int?,
        seconds: TimeInterval,
        enabled: Bool
    ) -> Double? {
        guard enabled, let tokens, tokens > 0, seconds > 0 else {
            return nil
        }
        return Double(tokens) / seconds
    }

    public static func shouldEstimateStreamingRates(baseURL: String) -> Bool {
        AgentRemoteProvider.isOpenRouterBaseURL(baseURL)
    }

    public func appendAssistantMessage(
        streamResult: RemoteStreamResult,
        to messages: inout [[String: Any]]
    ) {
        var message: [String: Any] = [
            "role": "assistant",
            "content": streamResult.text
        ]
        if !streamResult.toolCalls.isEmpty {
            message["tool_calls"] = streamResult.toolCalls.map { toolCall in
                [
                    "id": toolCall.id,
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ] as [String: Any]
            }
        }

        let hasContent = !streamResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        if hasContent || !streamResult.toolCalls.isEmpty {
            messages.append(message)
        }
    }
}
