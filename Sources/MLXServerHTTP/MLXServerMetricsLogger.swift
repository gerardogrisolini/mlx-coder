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

    init(sample: MLXServerMetricsSample) {
        timestamp = Date().ISO8601Format()
        endpoint = sample.endpoint
        protocolName = sample.protocolName
        runtimeKind = sample.runtimeKind.rawValue
        model = sample.model
        streamed = sample.streamed
        wallTime = sample.wallTime
        promptTokens = sample.promptTokens
        generationTokens = sample.generationTokens
        totalTokens = sample.promptTokens + sample.generationTokens
        promptTime = sample.promptTime
        generationTime = sample.generationTime
        promptTokensPerSecond = sample.promptTokensPerSecond
        generationTokensPerSecond = sample.generationTokensPerSecond
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
        case generationTokens = "generation_tokens"
        case totalTokens = "total_tokens"
        case promptTime = "prompt_time"
        case generationTime = "generation_time"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
    }
}
