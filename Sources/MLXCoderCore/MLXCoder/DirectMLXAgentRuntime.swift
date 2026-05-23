//
//  DirectMLXAgentRuntime.swift
//  MLXCoder
//
//  Created by Codex on 02/05/26.
//

import Foundation

public struct DirectAgentResponse: Sendable {
    public let text: String
    public let stopReason: String
    public let modelID: String
}

public struct DirectAgentToolCall: @unchecked Sendable {
    public let id: String
    public let name: String
    public let argumentsObject: [String: Any]
    public let argumentsJSON: String
}

public struct DirectAgentToolResult: Sendable {
    public let output: String
    public let summary: String
}

public struct DirectAgentGenerationMetrics: Sendable {
    public let promptTokenCount: Int?
    public let cachedPromptTokenCount: Int?
    public let promptTokensPerSecond: Double?
    public let completionTokenCount: Int?
    public let completionTokensPerSecond: Double?
    public let responseDurationSeconds: Double?
    public let contextTokenCount: Int?

    public init(
        promptTokenCount: Int?,
        cachedPromptTokenCount: Int? = nil,
        promptTokensPerSecond: Double?,
        completionTokenCount: Int?,
        completionTokensPerSecond: Double?,
        responseDurationSeconds: Double? = nil,
        contextTokenCount: Int? = nil
    ) {
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.promptTokensPerSecond = promptTokensPerSecond
        self.completionTokenCount = completionTokenCount
        self.completionTokensPerSecond = completionTokensPerSecond
        self.responseDurationSeconds = responseDurationSeconds
        self.contextTokenCount = contextTokenCount
    }

    public var totalTokenCount: Int? {
        if let contextTokenCount {
            return contextTokenCount
        }

        switch (promptTokenCount, completionTokenCount) {
        case let (prompt?, completion?):
            return prompt + (cachedPromptTokenCount ?? 0) + completion
        case let (prompt?, nil):
            return prompt + (cachedPromptTokenCount ?? 0)
        case let (nil, completion?):
            return (cachedPromptTokenCount ?? 0) + completion
        default:
            return cachedPromptTokenCount
        }
    }
}

public struct DirectAgentContextWindowStatus: Sendable {
    public let usedTokens: Int?
    public let maxTokens: Int?
    public let modelID: String
    public let isApproximate: Bool
}

public enum DirectAgentEvent: Sendable {
    case status(String)
    case diagnostic(String)
    case thought(String)
    case modelLoaded(String)
    case metrics(DirectAgentGenerationMetrics)
    case contextWindow(DirectAgentContextWindowStatus)
    case content(String)
    case toolCallStarted(DirectAgentToolCall)
    case toolCallCompleted(DirectAgentToolCall, DirectAgentToolResult)
}

public struct AgentKVCachePersistencePolicy {
    public static func terminalDiskCacheKey(workingDirectoryPath: String) -> String {
        "terminal:\(workingDirectoryPath)"
    }

    public static func shouldRestoreDiskCache(
        hasInMemoryCache: Bool,
        cacheKey: String?,
        historyContainsUserTurn: Bool
    ) -> Bool {
        !hasInMemoryCache
            && cacheKey?.nilIfBlank != nil
            && historyContainsUserTurn
    }

    public static func shouldPersistDiskCache(
        isFinalGenerationRound: Bool,
        cacheKey: String?,
        hasInMemoryCache: Bool
    ) -> Bool {
        isFinalGenerationRound
            && cacheKey?.nilIfBlank != nil
            && hasInMemoryCache
    }
}
