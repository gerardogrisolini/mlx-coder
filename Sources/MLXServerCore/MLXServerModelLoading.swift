//
//  MLXServerModelLoading.swift
//  mlx-server
//

import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Tokenizers

public enum MLXServerModelRuntimeKind: String, Codable, Sendable, Equatable, Hashable {
    case llm
    case vlm
}

public enum MLXServerModelLoading {
    public static func loadContainer(
        configuration: ModelConfiguration,
        runtimeKind: MLXServerModelRuntimeKind = .llm,
        useLatest: Bool = false,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> ModelContainer {
        _ = await MLXServerHuggingFaceCacheAccessStore.shared.activatePersistedAccess()
        let hubClient = MLXServerHuggingFaceCacheAccessStore.hubClient()
        return switch runtimeKind {
        case .llm:
            try await LLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hubClient),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                useLatest: useLatest,
                progressHandler: progressHandler
            )
        case .vlm:
            try await VLMModelFactory.shared.loadContainer(
                from: #hubDownloader(hubClient),
                using: #huggingFaceTokenizerLoader(),
                configuration: configuration,
                useLatest: useLatest,
                progressHandler: progressHandler
            )
        }
    }
}
