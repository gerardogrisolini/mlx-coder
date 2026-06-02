//
//  MLXServerMain.swift
//  mlx-server
//

import Foundation
import MLXCoderCore
import MLXLMCommon
import MLXServerCore
import MLXServerHTTP
import MLXServerSetup
import Dispatch

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct MLXServerMain {
    @MainActor
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.writeString("mlx-server: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(MLXServerHelp.text)
            return
        }

        if arguments.contains("--version") {
            print(MLXServerCore.serviceName)
            return
        }

        let didResetDiskCache = MLXServerResetDiskCacheCommand.shouldRun(arguments: arguments)
        let didResetConfiguration = MLXServerResetConfigurationCommand.shouldRun(arguments: arguments)
        if didResetDiskCache {
            try MLXServerResetDiskCacheCommand.run()
            arguments = MLXServerResetDiskCacheCommand.argumentsAfterRemovingOption(arguments: arguments)
        }
        if didResetConfiguration {
            try MLXServerResetConfigurationCommand.run()
            arguments = MLXServerResetConfigurationCommand.argumentsAfterRemovingOption(arguments: arguments)
        }
        if didResetDiskCache || didResetConfiguration, arguments.isEmpty {
            return
        }

        var didRunSetup = false
        if MLXServerSetupRunner.shouldRunSetup(arguments: arguments) {
            didRunSetup = true
            try MLXServerSetupRunner.run(arguments: arguments)
            arguments = MLXServerSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
        }

        if MLXServerModelSetupRunner.shouldRunSetup(arguments: arguments) {
            didRunSetup = true
            try await MLXServerModelSetupRunner.run(
                arguments: arguments,
                configureRetentionPolicy: true
            )
            arguments = MLXServerModelSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
        }

        if MLXServerAgentSetupRunner.shouldRunSetup(arguments: arguments) {
            didRunSetup = true
            try MLXServerAgentSetupRunner.run(arguments: arguments)
            arguments = MLXServerAgentSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
        }

        if didRunSetup, arguments.isEmpty {
            return
        }

        if arguments.contains("--coder") {
            try await runCoder(arguments: arguments)
            return
        }

        if arguments.contains("--chat") {
            let chatOptions = try MLXServerChatOptions(arguments: arguments)
            try MLXMetalLibraryBootstrap.prepareIfNeeded()
            let settings = try MLXServerSettingsStore.loadRequired()
            let modelCatalog = try MLXServerModelsManifestStore.loadRequired().catalog
            try await runChat(
                model: try modelCatalog.resolve(id: chatOptions.modelID),
                settings: settings,
                options: chatOptions
            )
            return
        }

        guard arguments.isEmpty else {
            throw MLXServerMainError.unsupportedArguments(arguments)
        }

        let settings = try MLXServerSettingsStore.loadRequired()
        let modelCatalog = try MLXServerModelsManifestStore.loadRequired().catalog
        try MLXMetalLibraryBootstrap.prepareIfNeeded()
        let runtime = MLXServerRuntime(
            retentionPolicy: settings.modelRetentionPolicy,
            diskKVCacheConfiguration: settings.diskKVCache.configuration,
            modelLoadLogger: logModelLoadEvent,
            modelUnloadLogger: logModelUnloadEvent
        )
        let transport = MLXServerHTTPTransportConfiguration(
            tlsCertificatePath: settings.tlsCertificatePath,
            tlsPrivateKeyPath: settings.tlsPrivateKeyPath,
            http2PriorKnowledge: settings.http2PriorKnowledge
        )
        let metricsLogger = try MLXServerMetricsLogger(
            destination: settings.metricsLogPath.map {
                .file(URL(fileURLWithPath: $0))
            } ?? .standardError
        )
        let server = MLXServerHTTPServer(
            configuration: settings.serverConfiguration,
            runtime: runtime,
            modelCatalog: modelCatalog,
            kvCacheSettings: settings.kvCache,
            transport: transport,
            apiKey: settings.apiKey,
            metricsLogger: metricsLogger,
            eventLoopThreadCount: settings.webServerThreadCount
        )
        try server.start()
        dispatchMain()
    }

    private static func runCoder(arguments: [String]) async throws {
        let options = try MLXServerCoderOptions(arguments: arguments)
        try ensureCoderProjectAgentsFileExists(workingDirectory: options.workingDirectory)
        try MLXMetalLibraryBootstrap.prepareIfNeeded()
        let settings = try MLXServerSettingsStore.loadRequired()
        let modelCatalog = try MLXServerModelsManifestStore.loadRequired().catalog
        let availableAgents = try AgentProfileStore.loadRequired()
        let initialModel = try modelCatalog.resolve(id: options.modelID)
        let runtime = MLXServerRuntime(
            retentionPolicy: settings.modelRetentionPolicy,
            diskKVCacheConfiguration: settings.diskKVCache.configuration,
            modelLoadLogger: nil,
            modelUnloadLogger: { logModelUnloadEvent($0, linePrefix: " ") }
        )
        let backendFactory: AgentRuntimeBackendFactory = { configuration, mcpRuntime in
            let model = try modelCatalog.resolve(
                id: configuration.modelID ?? initialModel.id
            )
            return MLXServerCoderBackend(
                configuration: configuration,
                runtime: runtime,
                model: model,
                mcpRuntime: mcpRuntime
            )
        }
        let permissionAuthorizer = LocalExecPermissionAuthorizer()
        let sessionRunner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorize(request)
            },
            backendFactory: backendFactory
        )
        let configuration = try AgentConfiguration(
            hostedModelID: initialModel.id,
            explicitModelID: options.modelID,
            agentName: options.agentName,
            availableAgents: availableAgents,
            availableModels: coderModelManifests(
                from: modelCatalog.models,
                kvCacheSettings: settings.kvCache
            ),
            cacheAgentProfiles: false,
            bearerToken: nil,
            runMode: options.acp ? .acp : .chat,
            workingDirectory: options.workingDirectory,
            initialSkillSelection: options.initialSkillSelection,
            maxToolRounds: options.maxToolRounds,
            maxOutputTokens: options.maxOutputTokens,
            verboseLogging: options.verboseLogging,
            appMode: false
        )
        if options.acp {
            if !options.verboseLogging {
                AgentOutput.silenceInheritedProcessError()
            }
            await runACP(configuration: configuration, backendFactory: backendFactory)
            return
        }

        let stdinIsTerminal = TerminalRawInput.supportsInteractiveInput()
        if stdinIsTerminal {
            AgentOutput.clearTerminalScreenIfNeeded()
        }
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner
        )

        do {
            try await terminal.run()
            await sessionRunner.shutdown()
        } catch {
            await sessionRunner.shutdown()
            throw error
        }
    }

    private static func runACP(
        configuration: AgentConfiguration,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async {
        let writer = ACPWriter()
        let bridge = MLXCoderACPBridge(
            configuration: configuration,
            writer: writer,
            backendFactory: backendFactory
        )
        let reader = StdioLineReader()
        let lines = AsyncStream<String> { continuation in
            let task = Task.detached {
                while let line = reader.readLine() {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for await line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    continue
                }
                group.addTask {
                    await bridge.handleLine(trimmedLine)
                }
            }
        }

        await bridge.shutdown()
    }

    private static func ensureCoderProjectAgentsFileExists(workingDirectory: URL) throws {
        let standardizedWorkingDirectory = workingDirectory.standardizedFileURL
        let agentsFileURL = standardizedWorkingDirectory
            .appendingPathComponent(MLXAgentsContextService.filename)
        guard !FileManager.default.fileExists(atPath: agentsFileURL.path) else {
            return
        }

        do {
            _ = try MLXProjectContextFileService().createDefaultDocument(
                kind: .agents,
                at: standardizedWorkingDirectory,
                projectName: standardizedWorkingDirectory.lastPathComponent
            )
        } catch {
            throw MLXServerMainError.unableToCreateProjectAgents(
                agentsFileURL,
                error
            )
        }
    }

    private static func coderModelManifests(
        from models: [MLXServerModelDescriptor],
        kvCacheSettings: MLXServerKVCacheSettings
    ) -> [AgentSettingsModelManifest] {
        let kvCacheSettings = kvCacheSettings.validated()
        let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000008080")!
        return models.map { model in
            let provider = AgentRemoteProvider(
                id: providerID,
                name: "mlx-server",
                baseURL: "http://127.0.0.1",
                modelID: model.id
            )
            return AgentSettingsModelManifest(
                id: model.id,
                kind: .remoteAPI,
                title: model.displayName,
                llmID: model.id,
                modelID: model.id,
                provider: provider,
                configuredContextWindowLimit: model.generationDefaults.contextWindow,
                generationParameterOverrides: AgentGenerationParameterOverrides(
                    maxTokens: model.generationDefaults.maxOutputTokens,
                    temperature: model.generationDefaults.temperature.map(Double.init),
                    topP: model.generationDefaults.topP.map(Double.init),
                    topK: model.generationDefaults.topK,
                    repetitionPenalty: model.generationDefaults.repetitionPenalty.map(Double.init),
                    presencePenalty: model.generationDefaults.presencePenalty.map(Double.init),
                    frequencyPenalty: model.generationDefaults.frequencyPenalty.map(Double.init),
                    prefillStepSize: model.generationDefaults.prefillStepSize
                        ?? MLXServerModelGenerationDefaults.defaultPrefillStepSize,
                    kvBits: kvCacheSettings.kvBits,
                    kvGroupSize: kvCacheSettings.kvGroupSize,
                    quantizedKVStart: kvCacheSettings.quantizedKVStart
                ),
                thinkingOptions: coderThinkingOptions(from: model.thinking),
                defaultThinkingSelection: AgentThinkingSelection(
                    rawValue: model.thinking.defaultSelection.rawValue
                )
            )
        }
    }

    private static func coderThinkingOptions(
        from thinking: MLXServerModelThinkingConfiguration
    ) -> [AgentThinkingSelection]? {
        guard thinking.supportsThinking else {
            return nil
        }
        let options = thinking.availableSelections.compactMap {
            AgentThinkingSelection(rawValue: $0.rawValue)
        }
        return options.isEmpty ? nil : options
    }

    private static func logModelLoadEvent(_ event: MLXServerModelLoadEvent) {
        logModelLoadEvent(event, linePrefix: "")
    }

    private static func logModelLoadEvent(
        _ event: MLXServerModelLoadEvent,
        linePrefix: String
    ) {
        let defaults = event.generationDefaults
        let parameters = event.parameters
        let kvCache = parameters.kvBits.map {
            "quantized(bits=\($0), group=\(parameters.kvGroupSize), start=\(parameters.quantizedKVStart))"
        } ?? "standard"
        let generationLine = [
            "context_window=\(formatModelDefault(defaults.contextWindow))",
            "max_output_tokens=\(formatModelDefault(parameters.maxTokens))",
            "temperature=\(format(parameters.temperature))",
            "top_p=\(format(parameters.topP))",
            "top_k=\(parameters.topK)",
            "min_p=\(format(parameters.minP))",
        ].joined(separator: ", ")
        let penaltiesLine = [
            "repetition=\(formatModelDefault(parameters.repetitionPenalty))",
            "presence=\(formatModelDefault(parameters.presencePenalty))",
            "frequency=\(formatModelDefault(parameters.frequencyPenalty))",
        ].joined(separator: ", ")

        let message = """
        mlx-server loaded model:
          model: \(event.modelID)
          runtime: \(event.runtimeKind.rawValue)
          generation: \(generationLine)
          penalties: \(penaltiesLine)
          kv_cache: \(kvCache), prefill_step_size=\(parameters.prefillStepSize)

        """
        FileHandle.standardError.writeString(
            coloredOperationalLog(linePrefixedLog(message, prefix: linePrefix))
        )
    }

    private static func logModelUnloadEvent(_ event: MLXServerModelUnloadEvent) {
        logModelUnloadEvent(event, linePrefix: "")
    }

    private static func logModelUnloadEvent(
        _ event: MLXServerModelUnloadEvent,
        linePrefix: String
    ) {
        let message = "mlx-server unloaded model: \(event.modelID)\n"
        FileHandle.standardError.writeString(
            coloredOperationalLog(linePrefixedLog(message, prefix: linePrefix))
        )
    }

    private static func formatModelDefault(_ value: Int?) -> String {
        value.map(String.init) ?? "model_default"
    }

    private static func formatModelDefault(_ value: Float?) -> String {
        value.map(format) ?? "model_default"
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    private static func coloredOperationalLog(_ message: String) -> String {
        guard isStandardErrorTerminal else {
            return message
        }
        return "\u{1B}[38;5;75m\(message)\u{1B}[0m"
    }

    private static func linePrefixedLog(_ message: String, prefix: String) -> String {
        guard !prefix.isEmpty else {
            return message
        }
        return message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : prefix + line
            }
            .joined(separator: "\n")
    }

    private static var isStandardErrorTerminal: Bool {
        isatty(FileHandle.standardError.fileDescriptor) == 1
    }

    private static func runChat(
        model: MLXServerModelDescriptor,
        settings: MLXServerSettings,
        options: MLXServerChatOptions
    ) async throws {
        let runtime = MLXServerRuntime(
            retentionPolicy: settings.modelRetentionPolicy,
            diskKVCacheConfiguration: settings.diskKVCache.configuration,
            modelLoadLogger: logModelLoadEvent,
            modelUnloadLogger: logModelUnloadEvent
        )
        let thinkingSelection = model.thinking.defaultEnabledSelection()
        var additionalContext = model.thinking.additionalContext(for: thinkingSelection)
        additionalContext["preserve_thinking"] = false
        var messages: [MLXServerChatMessage] = []
        var pendingInitialPrompt = options.initialPrompt
        var turnResults: [MLXServerChatTurnResult] = []
        var turnIndex = 1

        try await runtime.preloadModel(
            model: model,
            runtimeKind: model.runtimeKind,
            parameters: model.generationDefaults.generateParameters(
                maxTokens: options.maxTokens,
                kvCacheSettings: settings.kvCache
            )
        )

        if !options.quiet {
            FileHandle.standardError.writeString(
                """
                mlx-server chat
                model: \(model.id)
                end: Ctrl+D

                """
            )
        }

        while true {
            let userText: String
            if let initialPrompt = pendingInitialPrompt {
                pendingInitialPrompt = nil
                userText = initialPrompt
            } else {
                if !options.quiet {
                    FileHandle.standardError.writeString("mlx-server> ")
                }
                guard let line = readLine() else {
                    if !options.quiet {
                        FileHandle.standardError.writeString("\n")
                    }
                    break
                }
                userText = line
            }

            let trimmedUserText = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedUserText.isEmpty else {
                continue
            }

            let result = try await runChatTurn(
                runtime: runtime,
                model: model,
                messages: messages,
                userText: trimmedUserText,
                additionalContext: additionalContext,
                options: options,
                kvCacheSettings: settings.kvCache,
                label: "turn \(turnIndex)",
                printsOutput: !options.quiet
            )
            turnResults.append(result.metrics)
            messages.append(.user(trimmedUserText))
            messages.append(.assistant(result.visibleAssistantText))
            turnIndex += 1

        }

        if !turnResults.isEmpty {
            printSummary(for: turnResults)
        }
    }

    private static func runChatTurn(
        runtime: MLXServerRuntime,
        model: MLXServerModelDescriptor,
        messages: [MLXServerChatMessage],
        userText: String,
        additionalContext: [String: any Sendable],
        options: MLXServerChatOptions,
        kvCacheSettings: MLXServerKVCacheSettings,
        label: String,
        printsOutput: Bool
    ) async throws -> MLXServerChatTurnOutput {
        let request = MLXServerGenerationRequest(
            model: model,
            messages: messages + [.user(userText)],
            parameters: model.generationDefaults.generateParameters(
                maxTokens: options.maxTokens,
                kvCacheSettings: kvCacheSettings
            ),
            additionalContext: additionalContext,
            retainsReasoningInHistory: false
        )
        let stream = try await runtime.generateChatSession(request: request)
        var output = ""
        var completionInfo: GenerateCompletionInfo?

        for await event in stream {
            switch event {
            case .chunk(let chunk):
                output += chunk
                if printsOutput {
                    print(chunk, terminator: "")
                    fflush(stdout)
                }
            case .info(let info):
                completionInfo = info
            case .toolCall:
                break
            }
        }

        if printsOutput {
            print("\n")
        }

        guard let completionInfo else {
            throw MLXServerMainError.generationMissingMetrics
        }

        print("\(label) promptTokens: \(completionInfo.promptTokenCount)")
        print("\(label) generationTokens: \(completionInfo.generationTokenCount)")
        print("\(label) prefill: \(formattedRate(completionInfo.promptTokensPerSecond)) tok/s")
        print("\(label) generation: \(formattedRate(completionInfo.tokensPerSecond)) tok/s")

        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("\(label) warning: empty output")
        }

        return MLXServerChatTurnOutput(
            visibleAssistantText: MLXServerChatSessionTranscriptText.visibleAssistantContent(
                from: output,
                startsInThinking: request.emitsThinking
            ),
            metrics: MLXServerChatTurnResult(
                promptTokensPerSecond: completionInfo.promptTokensPerSecond,
                generationTokensPerSecond: completionInfo.tokensPerSecond
            )
        )
    }

    private static func printSummary(for results: [MLXServerChatTurnResult]) {
        let generationRates = results.map(\.generationTokensPerSecond)
        let minimum = generationRates.min() ?? 0
        let maximum = generationRates.max() ?? 0
        let average = generationRates.reduce(0, +) / Double(max(generationRates.count, 1))
        let median = median(generationRates)

        print("summaryGenerationMin: \(formattedRate(minimum)) tok/s")
        print("summaryGenerationMedian: \(formattedRate(median)) tok/s")
        print("summaryGenerationAverage: \(formattedRate(average)) tok/s")
        print("summaryGenerationMax: \(formattedRate(maximum)) tok/s")
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sortedValues = values.sorted()
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return (sortedValues[middle - 1] + sortedValues[middle]) / 2
        }
        return sortedValues[middle]
    }

    private static func formattedRate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }
}

private struct MLXServerCoderOptions {
    var modelID: String?
    var agentName: String?
    var workingDirectory: URL
    var initialSkillSelection: String?
    var maxToolRounds: Int
    var maxOutputTokens: Int?
    var verboseLogging: Bool
    var acp: Bool

    init(arguments: [String]) throws {
        var modelID: String?
        var agentName: String?
        var workingDirectoryPath = ProcessInfo.processInfo.environment["PWD"]
            ?? FileManager.default.currentDirectoryPath
        var initialSkillSelection: String?
        var maxToolRounds = 100
        var maxOutputTokens: Int?
        var verboseLogging = false
        var acp = false
        var didSeeCoder = false
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--coder":
                didSeeCoder = true
            case "--chat":
                throw MLXServerMainError.unsupportedArguments([argument])
            case "--model":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                modelID = value
            case "--agent":
                agentName = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--cwd":
                workingDirectoryPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--skills":
                initialSkillSelection = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--max-tool-rounds":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                maxToolRounds = parsed
            case "--max-output-tokens":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                maxOutputTokens = parsed
            case "--verbose":
                verboseLogging = true
            case "--acp":
                acp = true
            default:
                throw MLXServerMainError.unsupportedArguments([argument])
            }
            index = arguments.index(after: index)
        }

        guard didSeeCoder else {
            throw MLXServerMainError.missingRequiredArgument("--coder")
        }
        self.modelID = modelID
        self.agentName = agentName
        self.workingDirectory = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: workingDirectoryPath
        )
        self.initialSkillSelection = initialSkillSelection
        self.maxToolRounds = maxToolRounds
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.acp = acp
    }

    private static func requiredValue(
        after flag: String,
        in arguments: [String],
        index: inout Array<String>.Index
    ) throws -> String {
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw MLXServerMainError.missingRequiredArgument(flag)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private struct MLXServerChatOptions {
    var modelID: String?
    var initialPrompt: String?
    var maxTokens: Int?
    var quiet: Bool

    init(arguments: [String]) throws {
        var modelID: String?
        var initialPrompt: String?
        var maxTokens: Int?
        var quiet = false
        var didSeeChat = false

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--chat":
                didSeeChat = true
                let valueIndex = arguments.index(after: index)
                if valueIndex < arguments.endIndex,
                   !arguments[valueIndex].hasPrefix("-") {
                    initialPrompt = arguments[valueIndex]
                    index = valueIndex
                }
            case "--model":
                modelID = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--max-tokens":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                maxTokens = parsed
            case "--quiet":
                quiet = true
            default:
                throw MLXServerMainError.unsupportedArguments([argument])
            }
            index = arguments.index(after: index)
        }

        guard didSeeChat else {
            throw MLXServerMainError.missingRequiredArgument("--chat")
        }

        self.modelID = modelID
        self.initialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.maxTokens = maxTokens
        self.quiet = quiet
    }

    private static func requiredValue(
        after flag: String,
        in arguments: [String],
        index: inout Array<String>.Index
    ) throws -> String {
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw MLXServerMainError.missingRequiredArgument(flag)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private struct MLXServerChatTurnOutput {
    var visibleAssistantText: String
    var metrics: MLXServerChatTurnResult
}

private struct MLXServerChatTurnResult {
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double
}

private enum MLXServerMainError: LocalizedError {
    case unsupportedArguments([String])
    case missingRequiredArgument(String)
    case invalidArgument(String, String)
    case incompatibleArguments(String, String)
    case generationMissingMetrics
    case unableToCreateProjectAgents(URL, Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedArguments(let arguments):
            return "Unsupported arguments: \(arguments.joined(separator: " ")). Configure mlx-server with mlx-server --setup."
        case .missingRequiredArgument(let argument):
            return "Missing required value for \(argument)."
        case .invalidArgument(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        case .incompatibleArguments(let first, let second):
            return "\(first) cannot be used together with \(second)."
        case .generationMissingMetrics:
            return "Generation did not receive MLX completion metrics."
        case let .unableToCreateProjectAgents(url, error):
            return "Unable to create project AGENTS.md at \(url.path): \(error.localizedDescription)"
        }
    }
}

private enum MLXServerHelp {
    static let text = """
    mlx-server

    Usage:
      mlx-server [--help] [--version]
      mlx-server --setup
      mlx-server --setup-models
      mlx-server --setup-agents
      mlx-server --reset
      mlx-server --reset-disk-cache
      mlx-server
      mlx-server --coder [--acp] [--cwd <path>] [--model <id>] [--agent <name>] [--skills <list>]
                 [--max-output-tokens <count>] [--max-tool-rounds <count>] [--verbose]
      mlx-server --chat [initial text] [--model <id>] [--max-tokens <count>] [--quiet]

    Run mlx-server --setup once to create ~/.mlx-server/settings.json.
    Run mlx-server --setup-models directly to create or update ~/.mlx-server/models.json and download MLX models.
    Run mlx-coder --setup-agents to create or update mlx-coder profiles in ~/.mlx-coder/agents.json.
    Run mlx-server --setup-agents to configure Codex, Xcode, Claude Code, and Aion UI ACP integrations.
    Run mlx-server --reset to delete managed files in ~/.mlx-server and ~/.mlx-coder.
    Run mlx-server --reset-disk-cache to empty the configured disk KV cache directory. Default: ~/.mlx-server/KVCaches.
    Run mlx-server --coder to start the mlx-coder TUI with the local MLXServerRuntime directly, without HTTP or ACP.
    Add --acp to --coder to expose the direct local MLXServerRuntime to ACP clients such as Aion UI.
    Run mlx-server --chat to start an interactive terminal chat. Press Ctrl+D to exit.
    The server reads runtime settings from ~/.mlx-server/settings.json and models only from ~/.mlx-server/models.json.
    """
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
