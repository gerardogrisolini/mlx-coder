//
//  MLXServerModelSetupRunner+Types.swift
//  mlx-coder
//

import Foundation
import HuggingFace
import MLXServerCore

func repositoryDisplayName(_ repositoryID: String) -> String {
    repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
}

enum MLXServerModelSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Local MLX model setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-coder MLX model setup."
        }
    }
}

enum MLXServerModelSearchSelection: Equatable {
    case model(Int)
    case searchAgain
    case continueWithoutDownload
}

enum MLXServerModelSetupInputParser {
    static func parseSearchSelection(
        _ value: String,
        defaultSelection: Int,
        allowedRange: ClosedRange<Int>
    ) -> MLXServerModelSearchSelection? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedSearchCommand(trimmed)
        if searchAgainCommands.contains(normalized) {
            return .searchAgain
        }
        if continueWithoutDownloadCommands.contains(normalized) {
            return .continueWithoutDownload
        }

        let selectionText = trimmed.isEmpty ? String(defaultSelection) : trimmed
        guard let selection = Int(selectionText),
              allowedRange.contains(selection) else {
            return nil
        }
        return .model(selection)
    }

    private static let searchAgainCommands = Set([
        "s",
        "search",
        "search again",
        "again",
        "r",
        "retry",
        "cerca",
        "cerca ancora",
        "ricerca"
    ])

    private static let continueWithoutDownloadCommands = Set([
        "c",
        "continue",
        "continue without download",
        "skip",
        "skip download",
        "no download",
        "without download",
        "continua",
        "continua senza scaricare",
        "senza scaricare",
        "salta",
        "non scaricare"
    ])

    private static func normalizedSearchCommand(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum MLXServerHuggingFaceCacheRemovalResult: Equatable {
    case removed
    case notFound
    case invalidRepositoryID
}
enum MLXServerHuggingFaceCacheRemoval {
    static func remove(
        repositoryID: String,
        cache: HubCache,
        fileManager: FileManager = .default
    ) throws -> MLXServerHuggingFaceCacheRemovalResult {
        guard let repoID = Repo.ID(rawValue: repositoryID) else {
            return .invalidRepositoryID
        }

        let urls = removalURLs(repoID: repoID, cache: cache)
        var removedAny = false
        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else {
                continue
            }
            try fileManager.removeItem(at: url)
            removedAny = true
        }
        return removedAny ? .removed : .notFound
    }

    static func removalURLs(
        repositoryID: String,
        cache: HubCache
    ) -> [URL]? {
        guard let repoID = Repo.ID(rawValue: repositoryID) else {
            return nil
        }
        return removalURLs(repoID: repoID, cache: cache)
    }

    static func removalURLs(
        repoID: Repo.ID,
        cache: HubCache
    ) -> [URL] {
        let repositoryURL = cache.repoDirectory(repo: repoID, kind: .model)
        let metadataURL = cache.metadataDirectory(repo: repoID, kind: .model)
        return [
            repositoryURL,
            metadataURL,
            cache.lockPath(for: repositoryURL),
            cache.lockPath(for: metadataURL)
        ]
    }
}

struct ConfiguredModelRecord: Sendable {
    var record: MLXServerModelRecord
}

struct MLXServerCachedModelCandidate: Sendable {
    var repositoryID: String
    var revision: String
    var snapshotURL: URL

    var displayName: String {
        repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
    }
}

enum MLXServerCachedModelScanner {
    static func candidates(
        cache: HubCache = MLXServerHuggingFaceCacheAccessStore.cache,
        fileManager: FileManager = .default
    ) -> [MLXServerCachedModelCandidate] {
        guard let repositoryDirectories = try? fileManager.contentsOfDirectory(
            at: cache.cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return repositoryDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .flatMap { repositoryDirectory in
                candidates(
                    in: repositoryDirectory,
                    fileManager: fileManager
                )
            }
            .sorted {
                $0.repositoryID.localizedStandardCompare($1.repositoryID) == .orderedAscending
            }
    }

    private static func candidates(
        in repositoryDirectory: URL,
        fileManager: FileManager
    ) -> [MLXServerCachedModelCandidate] {
        guard let repositoryID = repositoryID(fromCacheDirectoryName: repositoryDirectory.lastPathComponent) else {
            return []
        }

        let snapshotsDirectory = repositoryDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirectories = try? fileManager.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return snapshotDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .filter { isUsableSnapshot($0, fileManager: fileManager) }
            .map {
                MLXServerCachedModelCandidate(
                    repositoryID: repositoryID,
                    revision: $0.lastPathComponent,
                    snapshotURL: $0
                )
            }
    }

    private static func repositoryID(fromCacheDirectoryName name: String) -> String? {
        guard name.hasPrefix("models--") else {
            return nil
        }

        let encodedRepositoryID = String(name.dropFirst("models--".count))
        let components = encodedRepositoryID.split(separator: "--", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return nil
        }

        let namespace = components[0]
        let repositoryName = components.dropFirst().joined(separator: "--")
        guard !namespace.isEmpty, !repositoryName.isEmpty else {
            return nil
        }
        return "\(namespace)/\(repositoryName)"
    }

    private static func isUsableSnapshot(
        _ snapshotURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(
            atPath: snapshotURL.appendingPathComponent("config.json").path
        ) else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent.lowercased()
            if filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
                || filename == "model.safetensors.index.json" {
                return true
            }
        }
        return false
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

enum MLXServerModelParameterImporter {
    static func importDefaults(from snapshotURL: URL) -> MLXServerModelGenerationDefaults {
        let config = decode(ModelConfigProbe.self, from: snapshotURL.appendingPathComponent("config.json"))
        let generationConfig = decode(
            GenerationConfigProbe.self,
            from: snapshotURL.appendingPathComponent("generation_config.json")
        )

        return MLXServerModelGenerationDefaults(
            contextWindow: config?.contextWindow,
            maxOutputTokens: generationConfig?.maxOutputTokensValue,
            temperature: generationConfig?.temperature,
            topP: generationConfig?.topP,
            topK: generationConfig?.topK,
            repetitionPenalty: generationConfig?.repetitionPenalty,
            presencePenalty: generationConfig?.presencePenalty,
            frequencyPenalty: generationConfig?.frequencyPenalty,
            prefillStepSize: MLXServerModelGenerationDefaults.defaultPrefillStepSize
        )
    }

    static func importThinking(
        from snapshotURL: URL,
        repositoryID: String
    ) -> MLXServerModelThinkingConfiguration {
        var detector = ModelThinkingMetadataDetector()
        detector.scan(repositoryID)

        for filename in ["config.json", "generation_config.json", "tokenizer_config.json"] {
            let fileURL = snapshotURL.appendingPathComponent(filename)
            if let value = decode(ModelMetadataValue.self, from: fileURL) {
                detector.scan(value)
            }
        }

        let templateURL = snapshotURL.appendingPathComponent("chat_template.jinja")
        if let data = try? Data(contentsOf: templateURL),
           let template = String(data: data, encoding: .utf8) {
            detector.scan(template)
        }

        return detector.configuration.validated()
    }

    private static func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

enum ModelMetadataValue: Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ModelMetadataValue])
    case object([String: ModelMetadataValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([ModelMetadataValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: ModelMetadataValue].self))
        }
    }
}

struct ModelThinkingMetadataDetector {
    var supportsThinking = false
    var supportsReasoningEffort = false
    var supportsPreserveThinking = false
    var effortLevels: [MLXServerThinkingSelection] = []

    var configuration: MLXServerModelThinkingConfiguration {
        guard supportsThinking else {
            return .disabled
        }
        if supportsReasoningEffort {
            return .effort(
                levels: effortLevels,
                supportsPreserveThinking: supportsPreserveThinking
            )
        }
        return MLXServerModelThinkingConfiguration(
            supportsThinking: true,
            supportsReasoningEffort: false,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off, .enabled],
            defaultSelection: .enabled
        )
    }

    mutating func scan(_ value: ModelMetadataValue, keyPath: [String] = []) {
        switch value {
        case .null:
            return
        case .bool(let bool):
            if bool, keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
            if bool, keyPath.contains(where: isEffortKey) {
                supportsThinking = true
                supportsReasoningEffort = true
            }
            if bool, keyPath.contains(where: isPreserveThinkingKey) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        case .number(let number):
            if number != 0, keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
        case .string(let string):
            scan(string, keyPath: keyPath)
        case .array(let array):
            for item in array {
                scan(item, keyPath: keyPath)
            }
        case .object(let object):
            for (key, nestedValue) in object {
                scanKey(key, value: nestedValue)
                scan(nestedValue, keyPath: keyPath + [key])
            }
        }
    }

    mutating func scan(_ text: String, keyPath: [String] = []) {
        if keyPath.contains(where: isEffortKey) {
            supportsThinking = true
            supportsReasoningEffort = true
            appendEffortLevel(from: text)
        }

        if keyPath.contains(where: isThinkingKey), isTruthy(text) {
            supportsThinking = true
        }

        if containsEnableThinkingReference(text) || isKnownThinkingModelIdentifier(text) {
            supportsThinking = true
        }

        if containsPreserveThinkingReference(text) || isKnownPreserveThinkingModelIdentifier(text) {
            supportsThinking = true
            supportsPreserveThinking = true
        }

        appendEffortLevel(from: text)
    }

    private mutating func scanKey(_ key: String, value: ModelMetadataValue) {
        if isThinkingKey(key), value.isTruthy {
            supportsThinking = true
        }

        if isEffortKey(key), value.isTruthy {
            supportsThinking = true
            supportsReasoningEffort = true
            appendEffortLevels(from: value)
        }

        if isPreserveThinkingKey(key), value.isTruthy {
            supportsThinking = true
            supportsPreserveThinking = true
        }

        let normalizedKey = normalizedToken(key)
        if normalizedKey == "chattemplate",
           case .string(let template) = value {
            if containsEnableThinkingReference(template) {
                supportsThinking = true
            }
            if containsPreserveThinkingReference(template) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        }
    }

    private mutating func appendEffortLevels(from value: ModelMetadataValue) {
        switch value {
        case .string(let string):
            appendEffortLevel(from: string)
        case .array(let array):
            for item in array {
                appendEffortLevels(from: item)
            }
        case .object(let object):
            for nestedValue in object.values {
                appendEffortLevels(from: nestedValue)
            }
        case .bool(let bool):
            if bool {
                supportsReasoningEffort = true
            }
        case .number, .null:
            return
        }
    }

    private mutating func appendEffortLevel(from value: String) {
        guard let selection = MLXServerThinkingSelection(protocolValue: value),
              selection.isEffortLevel,
              !effortLevels.contains(selection) else {
            return
        }
        supportsThinking = true
        supportsReasoningEffort = true
        effortLevels.append(selection)
    }

    private func isThinkingKey(_ key: String) -> Bool {
        let normalizedKey = normalizedToken(key)
        return normalizedKey == "reasoning"
            || normalizedKey == "thinking"
            || normalizedKey == "enablethinking"
            || normalizedKey == "reasoningcontent"
            || normalizedKey == "reasoningdetails"
    }

    private func isEffortKey(_ key: String) -> Bool {
        let normalizedKey = normalizedToken(key)
        return normalizedKey == "effort"
            || normalizedKey == "efforts"
            || normalizedKey == "reasoningeffort"
            || normalizedKey == "reasoningefforts"
            || normalizedKey == "thinkingeffort"
            || normalizedKey == "thinkingefforts"
            || normalizedKey == "effortlevels"
            || normalizedKey == "reasoningeffortlevels"
            || normalizedKey == "thinkinglevels"
    }

    private func isPreserveThinkingKey(_ key: String) -> Bool {
        normalizedToken(key) == "preservethinking"
    }

    private func containsEnableThinkingReference(_ value: String) -> Bool {
        normalizedToken(value).contains("enablethinking")
    }

    private func containsPreserveThinkingReference(_ value: String) -> Bool {
        normalizedToken(value).contains("preservethinking")
    }

    private func isKnownThinkingModelIdentifier(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue.contains("qwen3")
            || normalizedValue.contains("qwq")
            || normalizedValue.contains("reasoning")
            || normalizedValue.contains("thinking")
            || normalizedValue.contains("deepseekr1")
            || normalizedValue.contains("gptoss")
    }

    private func isKnownPreserveThinkingModelIdentifier(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue.contains("qwen36")
    }

    private func isTruthy(_ value: String) -> Bool {
        let normalizedValue = normalizedToken(value)
        return normalizedValue == "true"
            || normalizedValue == "enabled"
            || normalizedValue == "supported"
            || normalizedValue == "yes"
            || normalizedValue == "1"
            || normalizedValue.contains("reasoning")
            || normalizedValue.contains("thinking")
            || normalizedValue.contains("enablethinking")
    }

    private func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: " ", with: "")
    }
}

private extension ModelMetadataValue {
    var isTruthy: Bool {
        switch self {
        case .null:
            false
        case .bool(let bool):
            bool
        case .number(let number):
            number != 0
        case .string(let string):
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let array):
            !array.isEmpty
        case .object(let object):
            !object.isEmpty
        }
    }
}

struct ModelRuntimeKindProbe: Decodable {
    var modelType: String?
    var architectures: [String]?
    var textConfig: Nested?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case architectures
        case textConfig = "text_config"
    }

    var preferredTextRuntimeKind: MLXServerModelRuntimeKind? {
        for modelType in normalizedModelTypes {
            if Self.llmTextRuntimeModelTypes.contains(modelType) {
                return .llm
            }
        }

        for modelType in normalizedModelTypes {
            if Self.vlmOnlyModelTypes.contains(modelType) {
                return .vlm
            }
        }

        let architectureText = (architectures ?? [])
            .joined(separator: " ")
            .lowercased()
        if architectureText.contains("vision")
            || architectureText.contains("vlm")
            || architectureText.contains("llava") {
            return .vlm
        }

        return nil
    }

    private var normalizedModelTypes: [String] {
        [modelType, textConfig?.modelType]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static let llmTextRuntimeModelTypes: Set<String> = [
        "qwen3_5",
        "qwen3_5_moe",
        "gemma3",
        "gemma3n",
        "gemma4"
    ]

    private static let vlmOnlyModelTypes: Set<String> = [
        "fastvlm",
        "glm_ocr",
        "idefics3",
        "lfm2-vl",
        "lfm2_vl",
        "llava_qwen2",
        "mistral3",
        "paligemma",
        "pixtral",
        "qwen2_5_vl",
        "qwen2_vl",
        "qwen3_vl",
        "smolvlm"
    ]

    struct Nested: Decodable {
        var modelType: String?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }
}

struct GenerationConfigProbe: Decodable {
    var maxNewTokens: Int?
    var maxOutputTokens: Int?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var repetitionPenalty: Float?
    var presencePenalty: Float?
    var frequencyPenalty: Float?

    enum CodingKeys: String, CodingKey {
        case maxNewTokens = "max_new_tokens"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case repetitionPenalty = "repetition_penalty"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
    }

    var maxOutputTokensValue: Int? {
        maxOutputTokens ?? maxNewTokens
    }
}

struct ModelConfigProbe: Decodable {
    var maxPositionEmbeddings: Int?
    var maxContextLength: Int?
    var contextLength: Int?
    var modelMaxLength: Int?
    var maxSequenceLength: Int?
    var maxSequenceLen: Int?
    var textConfig: Nested?

    enum CodingKeys: String, CodingKey {
        case maxPositionEmbeddings = "max_position_embeddings"
        case maxContextLength = "max_context_length"
        case contextLength = "context_length"
        case modelMaxLength = "model_max_length"
        case maxSequenceLength = "max_sequence_length"
        case maxSequenceLen = "max_sequence_len"
        case textConfig = "text_config"
    }

    var contextWindow: Int? {
        [
            maxContextLength,
            contextLength,
            modelMaxLength,
            maxSequenceLength,
            maxSequenceLen,
            maxPositionEmbeddings,
            textConfig?.contextWindow
        ]
        .compactMap { $0 }
        .max()
    }

    struct Nested: Decodable {
        var maxPositionEmbeddings: Int?
        var maxContextLength: Int?
        var contextLength: Int?
        var modelMaxLength: Int?

        enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case maxContextLength = "max_context_length"
            case contextLength = "context_length"
            case modelMaxLength = "model_max_length"
        }

        var contextWindow: Int? {
            [
                maxContextLength,
                contextLength,
                modelMaxLength,
                maxPositionEmbeddings
            ]
            .compactMap { $0 }
            .max()
        }
    }
}

extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
