//
//  RemoteModelCatalogClient.swift
//  MLXCoder
//
//  Created by Codex on 24/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class RemoteModelCatalogClient {
    public static let defaultRequestTimeout: TimeInterval = 60 * 60
    public static let defaultResourceTimeout: TimeInterval = 60 * 60 * 8

    private let session: URLSession
    private let huggingFaceBaseURL: String
    private let enrichesHuggingFaceMetadata: Bool

    public init(
        urlSession: URLSession? = nil,
        huggingFaceBaseURL: String = "https://huggingface.co",
        enrichesHuggingFaceMetadata: Bool = true
    ) {
        self.huggingFaceBaseURL = AgentRemoteProvider.normalizedBaseURL(huggingFaceBaseURL)
        self.enrichesHuggingFaceMetadata = enrichesHuggingFaceMetadata
        if let urlSession {
            self.session = urlSession
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.defaultRequestTimeout
            configuration.timeoutIntervalForResource = Self.defaultResourceTimeout
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetchModels(
        baseURL: String,
        apiKey: String?
    ) async throws -> [OpenRouterModelInfo] {
        var request = try URLRequest(url: endpointURL(baseURL: baseURL, path: "models"))
        request.httpMethod = "GET"
        applyCommonHeaders(to: &request, apiKey: apiKey)

        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)

        let catalog = try decodeJSON(RemoteModelCatalogResponse.self, from: data)
        let models = catalog.data.compactMap { entry in
            modelInfo(from: entry, baseURL: baseURL)
        }
        return try await enrichModelsIfNeeded(models, baseURL: baseURL)
    }

    public func fetchModelMetadata(
        baseURL: String,
        modelID: String,
        apiKey: String?
    ) async throws -> OpenRouterModelMetadata? {
        let normalizedModelID = AgentRemoteProvider.normalizedModelID(modelID).lowercased()
        guard !normalizedModelID.isEmpty else {
            return nil
        }

        return try await fetchModels(baseURL: baseURL, apiKey: apiKey).first {
            AgentRemoteProvider.normalizedModelID($0.id).lowercased() == normalizedModelID
        }.map { model in
            OpenRouterModelMetadata(
                id: model.id,
                contextLength: model.contextLength,
                thinkingSupport: model.thinkingSupport,
                generationParameterOverrides: model.generationParameterOverrides
            )
        }
    }

    static func thinkingSupport(
        fromModelMetadata metadata: [String: Any],
        baseURL _: String,
        modelID _: String
    ) -> MLXModelThinkingSupport? {
        MLXModelThinkingSupport.fromModelMetadata(
            metadata.removingSparseIdentifierKeys()
        )
    }
}

public struct OpenRouterModelMetadata: Equatable, Sendable {
    public let id: String
    public let contextLength: Int?
    public let thinkingSupport: MLXModelThinkingSupport?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?

    public init(
        id: String,
        contextLength: Int?,
        thinkingSupport: MLXModelThinkingSupport?,
        generationParameterOverrides: AgentGenerationParameterOverrides? = nil
    ) {
        self.id = id
        self.contextLength = contextLength
        self.thinkingSupport = thinkingSupport
        self.generationParameterOverrides = generationParameterOverrides
    }
}

public struct OpenRouterModelInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int?
    public let pricing: OpenRouterModelPricing?
    public let thinkingSupport: MLXModelThinkingSupport?
    public let generationParameterOverrides: AgentGenerationParameterOverrides?
    public let installed: Bool?
    public let loaded: Bool?
    public let serverLoaded: Bool?

    public init(
        id: String,
        name: String,
        contextLength: Int?,
        pricing: OpenRouterModelPricing?,
        thinkingSupport: MLXModelThinkingSupport? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides? = nil,
        installed: Bool? = nil,
        loaded: Bool? = nil,
        serverLoaded: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.contextLength = contextLength
        self.pricing = pricing
        self.thinkingSupport = thinkingSupport
        self.generationParameterOverrides = generationParameterOverrides
        self.installed = installed
        self.loaded = loaded
        self.serverLoaded = serverLoaded
    }
}

public struct OpenRouterModelPricing: Equatable, Sendable {
    public let prompt: Double?
    public let completion: Double?

    public init(
        prompt: Double?,
        completion: Double?
    ) {
        self.prompt = prompt
        self.completion = completion
    }
}

public enum RemoteModelCatalogClientError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case serverError(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "RemoteAPI base URL is not valid: \(value)"
        case .invalidResponse:
            return "RemoteAPI returned an invalid response."
        case let .serverError(code, message):
            return "RemoteAPI error \(code): \(message)"
        }
    }
}

private extension RemoteModelCatalogClient {
    func modelInfo(
        from entry: RemoteModelCatalogEntry,
        baseURL: String
    ) -> OpenRouterModelInfo? {
        guard let id = stringValue(entry.values, "id")?.nilIfBlank else {
            return nil
        }

        let metadata = modelMetadata(from: entry)
        return OpenRouterModelInfo(
            id: id,
            name: stringValue(entry.values, "name")
                ?? stringValue(entry.values, "display_name")
                ?? id,
            contextLength: contextLength(from: entry.values),
            pricing: pricing(from: entry.values),
            thinkingSupport: Self.thinkingSupport(
                fromModelMetadata: metadata,
                baseURL: baseURL,
                modelID: id
            ),
            generationParameterOverrides: generationParameterOverrides(from: entry.values),
            installed: boolValue(entry.values, "installed"),
            loaded: boolValue(entry.values, "loaded"),
            serverLoaded: boolValue(entry.values, "server_loaded")
        )
    }

    func enrichModelsIfNeeded(
        _ models: [OpenRouterModelInfo],
        baseURL: String
    ) async throws -> [OpenRouterModelInfo] {
        guard shouldEnrichWithHuggingFace(baseURL: baseURL) else {
            return models
        }

        var enrichedModels: [OpenRouterModelInfo] = []
        enrichedModels.reserveCapacity(models.count)
        var metadataByRepositoryID: [String: HuggingFaceModelMetadata] = [:]
        for model in models {
            guard model.needsHuggingFaceMetadataEnrichment,
                  let repositoryID = Self.huggingFaceRepositoryID(from: model.id) else {
                enrichedModels.append(model)
                continue
            }

            let cacheKey = repositoryID.lowercased()
            let metadata: HuggingFaceModelMetadata?
            if let cachedMetadata = metadataByRepositoryID[cacheKey] {
                metadata = cachedMetadata
            } else {
                metadata = try await fetchHuggingFaceModelMetadata(repositoryID: repositoryID)
                if let metadata {
                    metadataByRepositoryID[cacheKey] = metadata
                }
            }
            enrichedModels.append(model.enriched(with: metadata))
        }
        return enrichedModels
    }

    func shouldEnrichWithHuggingFace(baseURL: String) -> Bool {
        enrichesHuggingFaceMetadata
            && !AgentRemoteProvider.isOpenRouterBaseURL(baseURL)
    }

    static func huggingFaceRepositoryID(from modelID: String) -> String? {
        let trimmedModelID = AgentRemoteProvider.normalizedModelID(modelID)
        guard !trimmedModelID.isEmpty else {
            return nil
        }
        let components = trimmedModelID
            .split(separator: "/")
            .map(String.init)
        guard components.count >= 2 else {
            return nil
        }
        let owner = components[0]
        guard !owner.contains(":") else {
            return nil
        }
        let repositoryName = components[1...].joined(separator: "/")
        guard !repositoryName.isEmpty else {
            return nil
        }
        return "\(owner)/\(repositoryName)"
    }

    func fetchHuggingFaceModelMetadata(
        repositoryID: String
    ) async throws -> HuggingFaceModelMetadata? {
        do {
            let apiResponse = try await fetchHuggingFaceAPIModel(repositoryID: repositoryID)
            let resolvedRepositoryID = apiResponse.repositoryID.nilIfBlank ?? repositoryID
                        var metadata = HuggingFaceModelMetadata(
                contextLength: contextLengthValue(apiResponse.rootValue),
                thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(
                    apiResponse.metadata.removingSparseIdentifierKeys()
                )
            )


            let siblingNames = Set(apiResponse.siblingFilenames.map { $0.lowercased() })
            if siblingNames.contains("config.json"),
               let config = try await fetchHuggingFaceJSONFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "config.json"
               ) {
                metadata.merge(
                    contextLength: contextLengthValue(config),
                    thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(config.anyValueDictionary)
                )
            }
            if siblingNames.contains("tokenizer_config.json"),
               let tokenizerConfig = try await fetchHuggingFaceJSONFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "tokenizer_config.json"
               ) {
                metadata.merge(
                    contextLength: contextLengthValue(tokenizerConfig),
                    thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(tokenizerConfig.anyValueDictionary)
                )
            }
            if siblingNames.contains("generation_config.json"),
               let generationConfig = try await fetchHuggingFaceJSONFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "generation_config.json"
               ) {
                metadata.merge(
                    contextLength: contextLengthValue(generationConfig),
                    thinkingSupport: MLXModelThinkingSupport.fromModelMetadata(generationConfig.anyValueDictionary)
                )
            }
            if siblingNames.contains("readme.md"),
               let readme = try await fetchHuggingFaceTextFile(
                   repositoryID: resolvedRepositoryID,
                   filename: "README.md"
               ) {
                metadata.merge(
                    contextLength: contextLength(fromText: readme),
                    thinkingSupport: Self.thinkingSupport(fromHuggingFaceReadme: readme)
                )
            }

            return metadata.isEmpty ? nil : metadata
        } catch {
            return nil
        }
    }

    func fetchHuggingFaceAPIModel(
        repositoryID: String
    ) async throws -> HuggingFaceAPIModelResponse {
        let data = try await fetchHuggingFaceData(path: "api/models/\(repositoryID)", accept: "application/json")
        let rootValue = try decodeJSON(JSONValue.self, from: data)
        let response = try decodeJSON(HuggingFaceAPIModelResponse.self, from: data)
        return HuggingFaceAPIModelResponse(
            id: response.id,
            modelID: response.modelID,
            siblings: response.siblings,
            rootValue: rootValue
        )
    }

    func fetchHuggingFaceJSONFile(
        repositoryID: String,
        filename: String
    ) async throws -> JSONValue? {
        do {
            let data = try await fetchHuggingFaceData(
                path: "\(repositoryID)/raw/main/\(filename)",
                accept: "application/json"
            )
            return try decodeJSON(JSONValue.self, from: data)
        } catch {
            return nil
        }
    }

    func fetchHuggingFaceTextFile(
        repositoryID: String,
        filename: String
    ) async throws -> String? {
        do {
            let data = try await fetchHuggingFaceData(
                path: "\(repositoryID)/raw/main/\(filename)",
                accept: "text/plain"
            )
            return String(data: data, encoding: .utf8)?.nilIfBlank
        } catch {
            return nil
        }
    }

    func fetchHuggingFaceData(
        path: String,
        accept: String
    ) async throws -> Data {
        let url = try huggingFaceURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("mlx-coder", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validateHTTPResponse(response, data: data)
        return data
    }

    func huggingFaceURL(path: String) throws -> URL {
        let sanitizedPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(huggingFaceBaseURL)/\(sanitizedPath)") else {
            throw RemoteModelCatalogClientError.invalidURL(huggingFaceBaseURL)
        }
        return url
    }

    static func thinkingSupport(fromHuggingFaceReadme readme: String) -> MLXModelThinkingSupport? {
        let lowercasedReadme = readme.lowercased()
        let compactReadme = normalizedMetadataKey(readme)
        let mentionsThinking = compactReadme.contains("reasoningmode")
            || compactReadme.contains("thinkingmode")
            || compactReadme.contains("reasoningeffort")
            || compactReadme.contains("nonthink")
            || compactReadme.contains("<think>")
            || compactReadme.contains("thinkingon")
            || compactReadme.contains("reasoningon")
        guard mentionsThinking else {
            return nil
        }

        var levels: [MLXThinkingSelection] = []
        func append(_ selection: MLXThinkingSelection) {
            guard !levels.contains(selection) else {
                return
            }
            levels.append(selection)
        }

        if containsWholeWord("minimal", in: lowercasedReadme) {
            append(.minimal)
        }
        if containsWholeWord("low", in: lowercasedReadme) {
            append(.low)
        }
        if containsWholeWord("medium", in: lowercasedReadme) {
            append(.medium)
        }
        if compactReadme.contains("thinkhigh")
            || compactReadme.contains("reasoningefforthigh")
            || lowercasedReadme.contains(#"reasoning_effort":"high"#)
            || lowercasedReadme.contains(#"reasoning_effort="high""#) {
            append(.high)
        }
        if compactReadme.contains("thinkmax")
            || compactReadme.contains("reasoningeffortmax")
            || compactReadme.contains("maximumreasoningeffort")
            || lowercasedReadme.contains(#"reasoning_effort":"max"#)
            || lowercasedReadme.contains(#"reasoning_effort="max""#) {
            append(.xhigh)
        }

        if !levels.isEmpty || compactReadme.contains("reasoningeffort") {
            return .effort(levels: levels)
        }
        return .generic
    }

    static func containsWholeWord(
        _ word: String,
        in text: String
    ) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#) else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    func endpointURL(
        baseURL: String,
        path: String
    ) throws -> URL {
        let normalizedBaseURL = AgentRemoteProvider.normalizedBaseURL(baseURL)
        guard let url = URL(string: "\(normalizedBaseURL)/\(path)") else {
            throw RemoteModelCatalogClientError.invalidURL(baseURL)
        }
        return url
    }

    func applyCommonHeaders(
        to request: inout URLRequest,
        apiKey: String?
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey = apiKey?.nilIfBlank {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("mlx-coder", forHTTPHeaderField: "X-Title")
    }

    func validateHTTPResponse(
        _ response: URLResponse,
        data: Data
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RemoteModelCatalogClientError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw RemoteModelCatalogClientError.serverError(
                httpResponse.statusCode,
                decodedServerMessage(from: data)
                    ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            )
        }
    }

    func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw RemoteModelCatalogClientError.invalidResponse
        }
    }

    func decodedServerMessage(from data: Data) -> String? {
        guard !data.isEmpty else {
            return nil
        }
        if let envelope = try? JSONDecoder().decode(RemoteModelCatalogErrorEnvelope.self, from: data),
           let message = envelope.error?.message?.nilIfBlank {
            return message
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }
}

private struct RemoteModelCatalogResponse: Decodable {
    let data: [RemoteModelCatalogEntry]
}

private struct RemoteModelCatalogEntry: Decodable {
    let values: [String: JSONValue]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: JSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.values = values
    }
}

private struct RemoteModelCatalogErrorEnvelope: Decodable {
    struct ErrorBody: Decodable {
        let message: String?
    }

    let error: ErrorBody?
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct HuggingFaceModelMetadata {
    var contextLength: Int?
    var thinkingSupport: MLXModelThinkingSupport?

    var isEmpty: Bool {
        contextLength == nil && thinkingSupport == nil
    }

    mutating func merge(
        contextLength: Int? = nil,
        thinkingSupport: MLXModelThinkingSupport? = nil
    ) {
        if self.contextLength == nil {
            self.contextLength = contextLength
        }
        if self.thinkingSupport == nil {
            self.thinkingSupport = thinkingSupport
        }
    }
}

private struct HuggingFaceAPIModelResponse: Decodable {
    struct Sibling: Decodable {
        let rfilename: String?
    }

    let id: String?
    let modelID: String?
    let siblings: [Sibling]
    let rootValue: JSONValue

    private enum CodingKeys: String, CodingKey {
        case id
        case modelID
        case siblings
    }

    init(
        id: String?,
        modelID: String?,
        siblings: [Sibling],
        rootValue: JSONValue
    ) {
        self.id = id
        self.modelID = modelID
        self.siblings = siblings
        self.rootValue = rootValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.modelID = try container.decodeIfPresent(String.self, forKey: .modelID)
        self.siblings = try container.decodeIfPresent([Sibling].self, forKey: .siblings) ?? []
        self.rootValue = .null
    }

    var repositoryID: String {
        modelID?.nilIfBlank ?? id?.nilIfBlank ?? ""
    }

    var metadata: [String: Any] {
        rootValue.anyValueDictionary
    }

    var siblingFilenames: [String] {
        siblings.compactMap { $0.rfilename?.nilIfBlank }
    }
}

private extension OpenRouterModelInfo {
    var needsHuggingFaceMetadataEnrichment: Bool {
        contextLength == nil || thinkingSupport == nil
    }

    func enriched(with metadata: HuggingFaceModelMetadata?) -> OpenRouterModelInfo {
        guard let metadata else {
            return self
        }
        return OpenRouterModelInfo(
            id: id,
            name: name,
            contextLength: contextLength ?? metadata.contextLength,
            pricing: pricing,
            thinkingSupport: thinkingSupport ?? metadata.thinkingSupport,
            generationParameterOverrides: generationParameterOverrides,
            installed: installed,
            loaded: loaded,
            serverLoaded: serverLoaded
        )
    }
}

private func modelMetadata(
    from entry: RemoteModelCatalogEntry
) -> [String: Any] {
    var metadata: [String: Any] = [:]
    for (key, value) in entry.values {
        metadata[key] = value.anyValue
    }
    return metadata
}

private func pricing(
    from object: [String: JSONValue]
) -> OpenRouterModelPricing? {
    guard let pricing = value(object, "pricing"),
          case let .object(pricingObject) = pricing else {
        return nil
    }
    return OpenRouterModelPricing(
        prompt: doubleValue(pricingObject, "prompt"),
        completion: doubleValue(pricingObject, "completion")
    )
}

private func generationParameterOverrides(
    from object: [String: JSONValue]
) -> AgentGenerationParameterOverrides? {
    guard let overrides = value(object, "generation_parameter_overrides"),
          case let .object(overridesObject) = overrides else {
        return nil
    }

    return AgentGenerationParameterOverrides(
        maxTokens: intValue(overridesObject, "max_tokens"),
        maxKVSize: intValue(overridesObject, "max_kv_size"),
        temperature: doubleValue(overridesObject, "temperature"),
        topP: doubleValue(overridesObject, "top_p"),
        topK: intValue(overridesObject, "top_k"),
        minP: doubleValue(overridesObject, "min_p"),
        repetitionPenalty: doubleValue(overridesObject, "repetition_penalty"),
        repetitionContextSize: intValue(overridesObject, "repetition_context_size"),
        presencePenalty: doubleValue(overridesObject, "presence_penalty"),
        presenceContextSize: intValue(overridesObject, "presence_context_size"),
        frequencyPenalty: doubleValue(overridesObject, "frequency_penalty"),
        frequencyContextSize: intValue(overridesObject, "frequency_context_size"),
        prefillStepSize: intValue(overridesObject, "prefill_step_size"),
        kvBits: intValue(overridesObject, "kv_bits"),
        kvGroupSize: intValue(overridesObject, "kv_group_size"),
        quantizedKVStart: intValue(overridesObject, "quantized_kv_start")
    ).normalized().nilIfEmpty
}

private func contextLength(
    from object: [String: JSONValue]
) -> Int? {
    contextLengthValue(.object(object))
}

private func contextLengthValue(
    _ value: JSONValue
) -> Int? {
    switch value {
    case let .object(object):
        for preferredKey in preferredContextLengthMetadataKeys {
            if let nestedValue = object.first(where: {
                normalizedMetadataKey($0.key) == preferredKey
            })?.value,
               let integer = contextLengthIntegerValue(nestedValue) {
                return integer
            }
        }

        for (key, nestedValue) in object where isContextLengthMetadataKey(key) {
            if let integer = contextLengthIntegerValue(nestedValue) {
                return integer
            }
        }

        for nestedValue in object.values {
            if let integer = contextLengthValue(nestedValue) {
                return integer
            }
        }
    case let .array(array):
        for item in array {
            if let integer = contextLengthValue(item) {
                return integer
            }
        }
    default:
        break
    }

    return nil
}

private var preferredContextLengthMetadataKeys: [String] {
    [
        "effectivecontextlength",
        "configuredcontextlength",
        "loadedcontextlength",
        "contextlength",
        "contextwindow",
        "maxcontextwindow",
        "samplingmaxcontextwindow",
        "maxcontextlength",
        "modelmaxlength",
        "modelmaxlen",
        "inputtokenlimit",
        "maxinputtokens",
        "maxmodellen",
        "maxmodellength",
        "maxsequencelength",
        "maxseqlen",
        "maxpositionembeddings",
        "npositions",
        "nctx"
    ]
}

private func contextLengthIntegerValue(
    _ value: JSONValue
) -> Int? {
    guard let integer = integerValue(value),
          integer >= 1024 else {
        return nil
    }
    return integer
}

private func isContextLengthMetadataKey(
    _ key: String
) -> Bool {
    preferredContextLengthMetadataKeys.contains(normalizedMetadataKey(key))
}

private func contextLength(
    fromText text: String
) -> Int? {
    let normalizedText = text.replacingOccurrences(of: ",", with: "")
    let patterns = [
        #"(?i)context\s+(?:length|window)[^\n\r\d]{0,40}(\d+(?:\.\d+)?)\s*([km])?\b"#,
        #"(?i)(\d+(?:\.\d+)?)\s*([km])?\s*(?:-|\s)?token\s+context\b"#,
        #"(?i)context\s+(?:length|window)[^\n\r\d]{0,40}(\d+)\b"#
    ]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            continue
        }
        let range = NSRange(normalizedText.startIndex..<normalizedText.endIndex, in: normalizedText)
        let matches = regex.matches(in: normalizedText, range: range)
        for match in matches {
            guard match.numberOfRanges >= 2,
                  let numberRange = Range(match.range(at: 1), in: normalizedText),
                  let number = Double(normalizedText[numberRange]) else {
                continue
            }
            let suffix: String?
            if match.numberOfRanges >= 3,
               let suffixRange = Range(match.range(at: 2), in: normalizedText) {
                suffix = String(normalizedText[suffixRange]).lowercased()
            } else {
                suffix = nil
            }
            let multiplier: Double
            switch suffix {
            case "m":
                multiplier = 1_000_000
            case "k":
                multiplier = 1_024
            default:
                multiplier = 1
            }
            let integer = Int(number * multiplier)
            if integer >= 1024 {
                return integer
            }
        }
    }
    return nil
}

private func normalizedMetadataKey(
    _ key: String
) -> String {
    key
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "_", with: "")
        .replacingOccurrences(of: "-", with: "")
        .replacingOccurrences(of: ".", with: "")
        .replacingOccurrences(of: " ", with: "")
}

private func value(
    _ object: [String: JSONValue],
    _ key: String
) -> JSONValue? {
    let normalizedKey = normalizedMetadataKey(key)
    return object.first { normalizedMetadataKey($0.key) == normalizedKey }?.value
}

private func stringValue(
    _ object: [String: JSONValue],
    _ key: String
) -> String? {
    value(object, key)?.stringValue?.nilIfBlank
}

private func boolValue(
    _ object: [String: JSONValue],
    _ key: String
) -> Bool? {
    value(object, key)?.boolValue
}

private func intValue(
    _ object: [String: JSONValue],
    _ key: String
) -> Int? {
    value(object, key).flatMap(integerValue)
}

private func doubleValue(
    _ object: [String: JSONValue],
    _ key: String
) -> Double? {
    value(object, key).flatMap(doubleValue)
}

private func integerValue(
    _ value: JSONValue
) -> Int? {
    switch value {
    case let .number(number):
        guard number.isFinite else {
            return nil
        }
        return Int(number)
    case let .string(string):
        let trimmedValue = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let integer = Int(trimmedValue) {
            return integer
        }

        let sanitizedValue = trimmedValue
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let integer = Int(sanitizedValue) {
            return integer
        }
        if let double = Double(sanitizedValue) {
            return Int(double)
        }
        return nil
    default:
        return nil
    }
}

private func doubleValue(
    _ value: JSONValue
) -> Double? {
    switch value {
    case let .number(number):
        return number.isFinite ? number : nil
    case let .string(string):
        return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

private extension Dictionary where Key == String, Value == Any {
    func removingSparseIdentifierKeys() -> [String: Any] {
        let sparseIdentifierKeys = Set([
            "id",
            "model",
            "modelid",
            "name",
            "modeltype",
            "architectures",
            "architecture"
        ])
        return filter { key, _ in
            !sparseIdentifierKeys.contains(normalizedMetadataKey(key))
        }
        .reduce(into: [:]) { result, element in
            result[element.key] = element.value
        }
    }
}

private extension JSONValue {
    var anyValueDictionary: [String: Any] {
        guard case let .object(object) = self else {
            return [:]
        }
        return object.mapValues(\.anyValue)
    }

    var anyValue: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .object(value):
            var object: [String: Any] = [:]
            for (key, nestedValue) in value {
                object[key] = nestedValue.anyValue
            }
            return object
        case let .array(value):
            return value.map(\.anyValue)
        case let .bool(value):
            return value
        case .null:
            return JSONValue.null
        }
    }
}
