//
//  MLXServerMetricsLogger.swift
//  mlx-server
//

import Foundation
import MLXServerCore

public actor MLXServerMetricsLogger {
    public enum Destination: Sendable {
        case standardError
        case file(URL)
    }

    private let encoder: JSONEncoder
    private let fileHandle: FileHandle
    private let closeOnDeinit: Bool

    public init(destination: Destination) throws {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        switch destination {
        case .standardError:
            fileHandle = .standardError
            closeOnDeinit = false
        case .file(let url):
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            fileHandle = try FileHandle(forWritingTo: url)
            try fileHandle.seekToEnd()
            closeOnDeinit = true
        }
    }

    deinit {
        if closeOnDeinit {
            try? fileHandle.close()
        }
    }

    func record(_ sample: MLXServerMetricsSample) {
        do {
            let record = MLXServerMetricsRecord(sample: sample)
            var data = try encoder.encode(record)
            data.append(10)
            try fileHandle.write(contentsOf: data)
        } catch {
            let fallback = "mlx-server metrics log failed: \(error.localizedDescription)\n"
            try? FileHandle.standardError.write(contentsOf: Data(fallback.utf8))
        }
    }
}

struct MLXServerMetricsSample: Sendable {
    var endpoint: String
    var protocolName: String
    var runtimeKind: MLXServerModelRuntimeKind
    var model: String
    var streamed: Bool
    var wallTime: Double
    var promptTokens: Int
    var generationTokens: Int
    var promptTime: Double
    var generationTime: Double
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double
    var cacheEvent: MLXServerChatCacheEvent?
}

private struct MLXServerMetricsRecord: Encodable {
    var timestamp: String
    var endpoint: String
    var protocolName: String
    var runtimeKind: String
    var model: String
    var streamed: Bool
    var wallTime: Double
    var promptTokens: Int
    var generationTokens: Int
    var totalTokens: Int
    var promptTime: Double
    var generationTime: Double
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double
    var cacheStatus: String?
    var processedPromptTokens: Int
    var cachedPromptTokens: Int?
    var cacheCachedSessionCount: Int?
    var cacheModelSessionCount: Int?
    var cachePriorTranscriptCount: Int?
    var cacheBestCommonPrefixCount: Int?
    var cacheBestCachedTranscriptCount: Int?
    var cacheBestModelCommonPrefixCount: Int?
    var cacheBestModelCachedTranscriptCount: Int?
    var cacheBestModelSameSystemSignature: Bool?
    var cacheBestModelSameToolsSignature: Bool?
    var cacheBestModelSameAdditionalContextSignature: Bool?
    var cacheBestModelSameMediaResizeSignature: Bool?
    var cacheBestModelSameReasoningRetention: Bool?
    var cacheRestoredPromptPrefixTokenCount: Int?

    init(sample: MLXServerMetricsSample) {
        timestamp = Date().ISO8601Format()
        endpoint = sample.endpoint
        protocolName = sample.protocolName
        runtimeKind = sample.runtimeKind.rawValue
        model = sample.model
        streamed = sample.streamed
        wallTime = sample.wallTime
        processedPromptTokens = sample.promptTokens
        cachedPromptTokens = sample.cacheEvent?.cachedPromptTokenCount
        promptTokens = sample.promptTokens + (cachedPromptTokens ?? 0)
        generationTokens = sample.generationTokens
        totalTokens = promptTokens + sample.generationTokens
        promptTime = sample.promptTime
        generationTime = sample.generationTime
        promptTokensPerSecond = sample.promptTokensPerSecond
        generationTokensPerSecond = sample.generationTokensPerSecond
        cacheStatus = sample.cacheEvent?.status.rawValue
        cacheCachedSessionCount = sample.cacheEvent?.cachedSessionCount
        cacheModelSessionCount = sample.cacheEvent?.modelSessionCount
        cachePriorTranscriptCount = sample.cacheEvent?.priorTranscriptCount
        cacheBestCommonPrefixCount = sample.cacheEvent?.bestCommonPrefixCount
        cacheBestCachedTranscriptCount = sample.cacheEvent?.bestCachedTranscriptCount
        cacheBestModelCommonPrefixCount = sample.cacheEvent?.bestModelCommonPrefixCount
        cacheBestModelCachedTranscriptCount = sample.cacheEvent?.bestModelCachedTranscriptCount
        cacheBestModelSameSystemSignature = sample.cacheEvent?.bestModelSameSystemSignature
        cacheBestModelSameToolsSignature = sample.cacheEvent?.bestModelSameToolsSignature
        cacheBestModelSameAdditionalContextSignature = sample.cacheEvent?.bestModelSameAdditionalContextSignature
        cacheBestModelSameMediaResizeSignature = sample.cacheEvent?.bestModelSameMediaResizeSignature
        cacheBestModelSameReasoningRetention = sample.cacheEvent?.bestModelSameReasoningRetention
        cacheRestoredPromptPrefixTokenCount = sample.cacheEvent?.restoredPromptPrefixTokenCount
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case endpoint
        case protocolName = "protocol"
        case runtimeKind = "runtime_kind"
        case model
        case streamed
        case wallTime = "wall_time"
        case promptTokens = "prompt_tokens"
        case processedPromptTokens = "prompt_tokens_processed"
        case cachedPromptTokens = "prompt_tokens_cached"
        case generationTokens = "generation_tokens"
        case totalTokens = "total_tokens"
        case promptTime = "prompt_time"
        case generationTime = "generation_time"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
        case cacheStatus = "chat_cache_status"
        case cacheCachedSessionCount = "chat_cache_cached_sessions"
        case cacheModelSessionCount = "chat_cache_model_sessions"
        case cachePriorTranscriptCount = "chat_cache_prior_transcript_messages"
        case cacheBestCommonPrefixCount = "chat_cache_best_common_prefix_messages"
        case cacheBestCachedTranscriptCount = "chat_cache_best_cached_transcript_messages"
        case cacheBestModelCommonPrefixCount = "chat_cache_best_model_common_prefix_messages"
        case cacheBestModelCachedTranscriptCount = "chat_cache_best_model_cached_transcript_messages"
        case cacheBestModelSameSystemSignature = "chat_cache_best_model_same_system_signature"
        case cacheBestModelSameToolsSignature = "chat_cache_best_model_same_tools_signature"
        case cacheBestModelSameAdditionalContextSignature = "chat_cache_best_model_same_additional_context_signature"
        case cacheBestModelSameMediaResizeSignature = "chat_cache_best_model_same_media_resize_signature"
        case cacheBestModelSameReasoningRetention = "chat_cache_best_model_same_reasoning_retention"
        case cacheRestoredPromptPrefixTokenCount = "chat_cache_restored_prompt_prefix_tokens"
    }
}
