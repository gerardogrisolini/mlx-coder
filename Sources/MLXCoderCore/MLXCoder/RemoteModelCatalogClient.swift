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

    public init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.defaultRequestTimeout
        configuration.timeoutIntervalForResource = Self.defaultResourceTimeout
        self.session = URLSession(configuration: configuration)
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
        return catalog.data.compactMap { entry in
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
        baseURL: String,
        modelID: String
    ) -> MLXModelThinkingSupport? {
        if let support = MLXModelThinkingSupport.fromModelMetadata(metadata) {
            return support
        }

        guard AgentRemoteProvider.isNVIDIABaseURL(baseURL)
            || AgentRemoteProvider.isModalDirectBaseURL(baseURL) else {
            return nil
        }

        if AgentRemoteProvider.isNVIDIABaseURL(baseURL),
           let support = inferredNVIDIAThinkingSupport(modelID: modelID) {
            return support
        }

        return MLXModelThinkingSupport.fromSparseRemoteModelIdentifier(modelID)
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
    static func inferredNVIDIAThinkingSupport(modelID: String) -> MLXModelThinkingSupport? {
        let normalizedID = normalizedSparseModelIdentifier(modelID)
        let hasNVIDIANemotronReasoningShape = [
            "cosmosreason",
            "nemotronreasoning",
            "nemotroncontentreasoning",
            "nemotronsuper",
            "nemotronultra",
            "nemotronnano",
            "nemotron3super",
            "nemotron3ultra",
            "nemotron3nano"
        ].contains { normalizedID.contains($0) }

        return hasNVIDIANemotronReasoningShape ? .generic : nil
    }

    static func normalizedSparseModelIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: " ", with: "")
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

private extension JSONValue {
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
