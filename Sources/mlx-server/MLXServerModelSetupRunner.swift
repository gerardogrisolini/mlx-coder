//
//  MLXServerModelSetupRunner.swift
//  mlx-server
//

import Foundation
import HuggingFace
import MLXServerCore
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

enum MLXServerModelSetupRunner {
    static let option = "--setup-models"

    static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    static func run(arguments: [String], configureRetentionPolicy: Bool = true) async throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerModelSetupError.nonInteractiveTerminal
        }

        let modelsURL = MLXServerModelsManifestStore.modelsURL()
        FileHandle.standardError.writeString(
            """
            mlx-server models setup
            Configuro models.json in:
            \(modelsURL.path)

            """
        )

        if configureRetentionPolicy {
            try configureModelRetentionPolicy()
        }

        var manifest = MLXServerModelsManifest()
        let isFirstSetup = !FileManager.default.fileExists(atPath: modelsURL.path)
        if !isFirstSetup {
            do {
                manifest = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
                printExistingModels(manifest)
                let shouldContinue = try promptYesNo(
                    "Vuoi aggiungere o aggiornare un modello?",
                    defaultValue: true
                )
                guard shouldContinue else {
                    FileHandle.standardError.writeString("\nSetup modelli completato. Avvio mlx-server.\n\n")
                    return
                }
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "models.json esiste ma non e valido. Vuoi riscriverlo?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        if isFirstSetup {
            try importCachedModelsIfRequested(into: &manifest)
        }

        let shouldConfigureRemoteModel: Bool
        if manifest.models.isEmpty {
            shouldConfigureRemoteModel = true
        } else {
            shouldConfigureRemoteModel = try promptYesNo(
                "Cercare e scaricare un modello da Hugging Face?",
                defaultValue: false
            )
        }
        if shouldConfigureRemoteModel {
            repeat {
                let record = try await configureRemoteModel()
                upsert(record: record, in: &manifest)
                try updateDefaultModel(afterAdding: record, in: &manifest)
            } while try promptYesNo("Aggiungere un altro modello?", defaultValue: false)
        }

        try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
        FileHandle.standardError.writeString("Aggiornato: models.json\n")
        FileHandle.standardError.writeString("\nSetup modelli completato. Avvio mlx-server.\n\n")
    }

    private static func configureModelRetentionPolicy() throws {
        let settingsURL = MLXServerSettingsStore.settingsURL()
        let settingsExists = FileManager.default.fileExists(atPath: settingsURL.path)
        var settings = settingsExists
            ? try MLXServerSettingsStore.loadRequired(from: settingsURL)
            : MLXServerSettings()

        settings.loadOneModelAtATime = try promptYesNo(
            "Vuoi che il server carichi solo un modello alla volta?",
            defaultValue: settings.loadOneModelAtATime
        )

        try MLXServerSettingsStore.save(settings, to: settingsURL)
        FileHandle.standardError.writeString("Aggiornato: settings.json\n\n")
    }

    private static func importCachedModelsIfRequested(into manifest: inout MLXServerModelsManifest) throws {
        let candidates = MLXServerCachedModelScanner.candidates()
        guard !candidates.isEmpty else {
            return
        }

        FileHandle.standardError.writeString(
            """
            Trovati modelli gia scaricati nella cache Hugging Face:

            """
        )
        for (index, candidate) in candidates.enumerated() {
            FileHandle.standardError.writeString(
                "\(index + 1). \(candidate.repositoryID) [\(candidate.revision)]\n"
            )
        }
        FileHandle.standardError.writeString("\n")

        guard try promptYesNo(
            "Vuoi importarli in models.json?",
            defaultValue: true
        ) else {
            return
        }

        for candidate in candidates {
            guard try promptYesNo(
                "Importare \(candidate.repositoryID)?",
                defaultValue: true
            ) else {
                continue
            }
            let record = try configureCachedModel(candidate)
            upsert(record: record, in: &manifest)
            try updateDefaultModel(afterAdding: record, in: &manifest)
        }
    }

    private static func configureRemoteModel() async throws -> MLXServerModelRecord {
        let client = HubClient.default
        let selectedModel = try await selectHuggingFaceModel(client: client)
        let repositoryID = selectedModel.id.rawValue
        let revision = selectedModel.sha ?? "main"

        FileHandle.standardError.writeString("\nScarico \(repositoryID) [\(revision)]...\n")
        let snapshotURL = try await client.downloadSnapshot(
            of: selectedModel.id,
            revision: revision
        )
        FileHandle.standardError.writeString("\nDownload completato: \(snapshotURL.path)\n")

        return try configureModelRecord(
            repositoryID: repositoryID,
            revision: revision,
            snapshotURL: snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(from: selectedModel)
        )
    }

    private static func configureCachedModel(_ candidate: MLXServerCachedModelCandidate) throws -> MLXServerModelRecord {
        try configureModelRecord(
            repositoryID: candidate.repositoryID,
            revision: candidate.revision,
            snapshotURL: candidate.snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(from: candidate)
        )
    }

    private static func configureModelRecord(
        repositoryID: String,
        revision: String,
        snapshotURL: URL,
        defaultRuntimeKind: MLXServerModelRuntimeKind
    ) throws -> MLXServerModelRecord {
        let importedDefaults = MLXServerModelParameterImporter.importDefaults(from: snapshotURL)
        let importedThinking = MLXServerModelParameterImporter.importThinking(
            from: snapshotURL,
            repositoryID: repositoryID
        )
        let id = try promptString(
            "ID modello esposto dal server",
            defaultValue: repositoryID,
            allowEmpty: false
        )
        let generationDefaults = try configureGenerationDefaults(importedDefaults)
        let thinking = try configureThinking(importedThinking)

        return try MLXServerModelRecord(
            id: id,
            displayName: repositoryDisplayName(repositoryID),
            repositoryID: repositoryID,
            revision: revision,
            runtimeKind: defaultRuntimeKind,
            enabled: true,
            generationDefaults: generationDefaults,
            thinking: thinking
        ).validated()
    }

    private static func configureGenerationDefaults(
        _ defaults: MLXServerModelGenerationDefaults
    ) throws -> MLXServerModelGenerationDefaults {
        let contextWindow = try promptInt(
            "Finestra di contesto",
            defaultValue: defaults.contextWindow ?? 32_768,
            allowedRange: 1...Int.max
        )
        let maxOutputTokens = try promptInt(
            "Max tokens in output",
            defaultValue: defaults.maxOutputTokens ?? 4_096,
            allowedRange: 1...Int.max
        )
        let temperature = try promptFloat(
            "Temperature",
            defaultValue: defaults.temperature ?? 0.6,
            allowedRange: 0...Float.greatestFiniteMagnitude
        )
        let topP = try promptFloat(
            "top_p",
            defaultValue: defaults.topP ?? 1.0,
            allowedRange: 0...1
        )
        let topK = try promptInt(
            "top_k",
            defaultValue: defaults.topK ?? 0,
            allowedRange: 0...Int.max
        )
        let presencePenalty = try promptFloat(
            "presence_penalty",
            defaultValue: defaults.presencePenalty ?? 0,
            allowedRange: -2...2
        )
        let frequencyPenalty = try promptFloat(
            "frequency_penalty",
            defaultValue: defaults.frequencyPenalty ?? 0,
            allowedRange: -2...2
        )

        return MLXServerModelGenerationDefaults(
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty
        )
    }

    private static func configureThinking(
        _ defaults: MLXServerModelThinkingConfiguration
    ) throws -> MLXServerModelThinkingConfiguration {
        let normalizedDefaults = defaults.validated()
        let supportsThinking = try promptYesNo(
            "Il modello supporta thinking?",
            defaultValue: normalizedDefaults.supportsThinking
        )
        guard supportsThinking else {
            return .disabled
        }

        let supportsReasoningEffort = try promptYesNo(
            "Supporta livelli di thinking?",
            defaultValue: normalizedDefaults.supportsReasoningEffort
        )
        let supportsPreserveThinking = try promptYesNo(
            "Preservare il thinking nella history quando il protocollo lo richiede?",
            defaultValue: normalizedDefaults.supportsPreserveThinking
        )

        guard supportsReasoningEffort else {
            return MLXServerModelThinkingConfiguration(
                supportsThinking: true,
                supportsReasoningEffort: false,
                supportsPreserveThinking: supportsPreserveThinking,
                availableSelections: [.off, .enabled],
                defaultSelection: .enabled
            ).validated()
        }

        let defaultLevels = MLXServerModelThinkingConfiguration.normalizedEffortLevels(
            from: normalizedDefaults.availableSelections
        )
        let levels = try promptThinkingLevels(
            "Livelli thinking disponibili",
            defaultValue: defaultLevels.isEmpty
                ? [.minimal, .low, .medium, .high, .xhigh]
                : defaultLevels
        )
        let defaultSelection = try promptThinkingSelection(
            "Livello thinking default",
            defaultValue: normalizedDefaults.defaultSelection.isEffortLevel
                ? normalizedDefaults.defaultSelection
                : (levels.contains(.medium) ? .medium : levels[0]),
            availableLevels: levels
        )

        return MLXServerModelThinkingConfiguration(
            supportsThinking: true,
            supportsReasoningEffort: true,
            supportsPreserveThinking: supportsPreserveThinking,
            availableSelections: [.off] + levels,
            defaultSelection: defaultSelection
        ).validated()
    }

    private static func selectHuggingFaceModel(client: HubClient) async throws -> Model {
        while true {
            let query = try promptString(
                "Ricerca Hugging Face MLX",
                defaultValue: nil,
                allowEmpty: true
            ).trimmedNonEmpty

            let response = try await client.listModels(
                search: query,
                filter: "mlx",
                sort: "downloads",
                direction: .descending,
                limit: 10,
                full: true,
                expand: [
                    .known(.downloads),
                    .known(.likes),
                    .known(.libraryName),
                    .known(.pipelineTag),
                    .known(.siblings),
                    .known(.tags),
                    .known(.config)
                ],
                fetchConfig: true
            )

            let models = response.items.filter(isUsableMLXModel)
            guard !models.isEmpty else {
                FileHandle.standardError.writeString("Nessun modello MLX trovato.\n")
                continue
            }

            FileHandle.standardError.writeString("\n")
            for (index, model) in models.enumerated() {
                let downloads = model.downloads.map { "\($0) download" } ?? "download n/d"
                let likes = model.likes.map { "\($0) like" } ?? "like n/d"
                FileHandle.standardError.writeString(
                    "\(index + 1). \(model.id.rawValue) - \(downloads), \(likes)\n"
                )
            }

            let selection = try promptInt(
                "Seleziona modello",
                defaultValue: 1,
                allowedRange: 1...models.count
            )
            return models[selection - 1]
        }
    }

    private static func isUsableMLXModel(_ model: Model) -> Bool {
        let tags = model.tags ?? []
        let hasMLXTag = tags.contains { $0.localizedCaseInsensitiveContains("mlx") }
        let hasModelFiles = model.siblings?.contains { sibling in
            let filename = sibling.relativeFilename.lowercased()
            return filename == "config.json"
                || filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
        } ?? true
        return hasMLXTag && hasModelFiles && model.isDisabled != true
    }

    private static func inferredRuntimeKind(from model: Model) -> MLXServerModelRuntimeKind {
        let searchable = ((model.tags ?? []) + [model.pipelineTag, model.library].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    private static func inferredRuntimeKind(from candidate: MLXServerCachedModelCandidate) -> MLXServerModelRuntimeKind {
        let searchable = candidate.repositoryID.lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm")
            || FileManager.default.fileExists(
                atPath: candidate.snapshotURL.appendingPathComponent("preprocessor_config.json").path
            )
            || FileManager.default.fileExists(
                atPath: candidate.snapshotURL.appendingPathComponent("image_processor_config.json").path
            )
            || FileManager.default.fileExists(
                atPath: candidate.snapshotURL.appendingPathComponent("processor_config.json").path
            ) {
            return .vlm
        }
        return .llm
    }

    private static func upsert(
        record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) {
        if let index = manifest.models.firstIndex(where: { $0.id == record.id }) {
            manifest.models[index] = record
        } else {
            manifest.models.append(record)
        }
    }

    private static func updateDefaultModel(
        afterAdding record: MLXServerModelRecord,
        in manifest: inout MLXServerModelsManifest
    ) throws {
        if manifest.defaultModelID == nil || manifest.models.count == 1 {
            manifest.defaultModelID = record.id
            return
        }
        if try promptYesNo("Impostare \(record.id) come modello default?", defaultValue: false) {
            manifest.defaultModelID = record.id
        }
    }

    private static func printExistingModels(_ manifest: MLXServerModelsManifest) {
        guard !manifest.models.isEmpty else {
            return
        }
        FileHandle.standardError.writeString("Modelli configurati:\n")
        for model in manifest.models {
            let marker = model.id == manifest.defaultModelID ? "*" : " "
            FileHandle.standardError.writeString("\(marker) \(model.id) -> \(model.repositoryID)\n")
        }
        FileHandle.standardError.writeString("\n")
    }

    private static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            FileHandle.standardError.writeString("\(prompt)\(suffix): ")
            guard let line = readLine() else {
                throw MLXServerModelSetupError.inputClosed
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, let defaultValue {
                return defaultValue
            }
            if trimmed.isEmpty, allowEmpty {
                return ""
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    private static func promptInt(
        _ prompt: String,
        defaultValue: Int,
        allowedRange: ClosedRange<Int>
    ) throws -> Int {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Int(value), allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Valore non valido.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptFloat(
        _ prompt: String,
        defaultValue: Float,
        allowedRange: ClosedRange<Float>
    ) throws -> Float {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: formatFloat(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Float(value.replacingOccurrences(of: ",", with: ".")),
                  allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Valore non valido.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptThinkingLevels(
        _ prompt: String,
        defaultValue: [MLXServerThinkingSelection]
    ) throws -> [MLXServerThinkingSelection] {
        let resolvedDefault = MLXServerModelThinkingConfiguration.normalizedEffortLevels(
            from: defaultValue
        )
        let defaultString = formatThinkingLevels(
            resolvedDefault.isEmpty ? [.minimal, .low, .medium, .high, .xhigh] : resolvedDefault
        )

        while true {
            let value = try promptString(
                prompt,
                defaultValue: defaultString,
                allowEmpty: false
            )
            let levels = MLXServerModelThinkingConfiguration.normalizedEffortLevels(
                from: value
                    .split(separator: ",")
                    .compactMap { MLXServerThinkingSelection(protocolValue: String($0)) }
            )
            guard !levels.isEmpty else {
                FileHandle.standardError.writeString("Valore non valido. Usa per esempio: low, medium, high\n")
                continue
            }
            return levels
        }
    }

    private static func promptThinkingSelection(
        _ prompt: String,
        defaultValue: MLXServerThinkingSelection,
        availableLevels: [MLXServerThinkingSelection]
    ) throws -> MLXServerThinkingSelection {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: defaultValue.rawValue,
                allowEmpty: false
            )
            guard let selection = MLXServerThinkingSelection(protocolValue: value),
                  selection.isEffortLevel,
                  availableLevels.contains(selection) else {
                FileHandle.standardError.writeString(
                    "Valore non valido. Disponibili: \(formatThinkingLevels(availableLevels))\n"
                )
                continue
            }
            return selection
        }
    }

    private static func formatThinkingLevels(_ levels: [MLXServerThinkingSelection]) -> String {
        MLXServerModelThinkingConfiguration.normalizedEffortLevels(from: levels)
            .map(\.rawValue)
            .joined(separator: ", ")
    }

    private static func formatFloat(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    private static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            FileHandle.standardError.writeString("\(prompt) [\(defaultLabel)]: ")
            guard let line = readLine() else {
                throw MLXServerModelSetupError.inputClosed
            }
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                return defaultValue
            }
            if ["y", "yes", "s", "si", "sì"].contains(normalized) {
                return true
            }
            if ["n", "no"].contains(normalized) {
                return false
            }
        }
    }

    private static func supportsInteractiveInput() -> Bool {
        #if os(macOS) || os(Linux)
        return isatty(STDIN_FILENO) == 1
        #else
        return true
        #endif
    }
}

private func repositoryDisplayName(_ repositoryID: String) -> String {
    repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
}

enum MLXServerModelSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-server --setup-models requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-server model setup."
        }
    }
}

private struct MLXServerCachedModelCandidate: Sendable {
    var repositoryID: String
    var revision: String
    var snapshotURL: URL

    var displayName: String {
        repositoryID.split(separator: "/", maxSplits: 1).last.map(String.init) ?? repositoryID
    }
}

private enum MLXServerCachedModelScanner {
    static func candidates(
        cache: HubCache = .default,
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

private enum MLXServerModelParameterImporter {
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
            presencePenalty: generationConfig?.presencePenalty,
            frequencyPenalty: generationConfig?.frequencyPenalty
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

private enum ModelMetadataValue: Decodable {
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

private struct ModelThinkingMetadataDetector {
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

        if containsPreserveThinkingReference(text) {
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

private struct GenerationConfigProbe: Decodable {
    var maxNewTokens: Int?
    var maxOutputTokens: Int?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var presencePenalty: Float?
    var frequencyPenalty: Float?

    enum CodingKeys: String, CodingKey {
        case maxNewTokens = "max_new_tokens"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
    }

    var maxOutputTokensValue: Int? {
        maxOutputTokens ?? maxNewTokens
    }
}

private struct ModelConfigProbe: Decodable {
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

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
