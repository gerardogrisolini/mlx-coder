//
//  MLXServerMain.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore
import MLXServerHTTP
import Dispatch

@main
struct MLXServerMain {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.writeString("mlx-server: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

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

        var shouldRunModelSetup = false
        if MLXServerSetupRunner.shouldRunSetup(arguments: arguments) {
            shouldRunModelSetup = try MLXServerSetupRunner.run(arguments: arguments)
            arguments = MLXServerSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
        }

        if shouldRunModelSetup || MLXServerModelSetupRunner.shouldRunSetup(arguments: arguments) {
            try await MLXServerModelSetupRunner.run(
                arguments: arguments,
                configureRetentionPolicy: !shouldRunModelSetup
            )
            arguments = MLXServerModelSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
        }

        if MLXServerAgentSetupRunner.shouldRunSetup(arguments: arguments) {
            try MLXServerAgentSetupRunner.run(arguments: arguments)
            arguments = MLXServerAgentSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
        }

        if arguments.contains("--prompt") {
            let benchmarkOptions = try MLXServerBenchmarkOptions(arguments: arguments)
            try MLXMetalLibraryBootstrap.prepareIfNeeded()
            let modelCatalog = try MLXServerModelsManifestStore.loadRequired().catalog
            try await runBenchmark(
                model: try modelCatalog.resolve(id: benchmarkOptions.modelID),
                options: benchmarkOptions
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
            diskKVCacheConfiguration: settings.diskKVCache.configuration
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
            transport: transport,
            metricsLogger: metricsLogger
        )
        try server.start()
        dispatchMain()
    }

    private static func runBenchmark(
        model: MLXServerModelDescriptor,
        options: MLXServerBenchmarkOptions
    ) async throws {
        let runtime = MLXServerRuntime()

        print("model: \(model.id)")
        print("prompt: \(options.prompt)")
        if let maxTokens = options.maxTokens {
            print("maxTokens: \(maxTokens)")
        } else {
            print("maxTokens: unlimited")
        }
        print("warmups: \(options.warmupRuns)")
        print("runs: \(options.measuredRuns)")
        if let minimumGenerationTokensPerSecond = options.minimumGenerationTokensPerSecond {
            print(
                "minimumGenerationTokensPerSecond: \(formattedRate(minimumGenerationTokensPerSecond)) tok/s"
            )
        }
        fflush(stdout)

        if options.warmupRuns > 0 {
            for index in 1...options.warmupRuns {
                _ = try await runBenchmarkOnce(
                    runtime: runtime,
                    model: model,
                    options: options,
                    label: "warmup \(index)",
                    printsOutput: false
                )
            }
        }

        var measuredResults: [MLXServerBenchmarkRunResult] = []
        for index in 1...options.measuredRuns {
            let result = try await runBenchmarkOnce(
                runtime: runtime,
                model: model,
                options: options,
                label: "run \(index)",
                printsOutput: !options.quiet
            )
            measuredResults.append(result)
        }

        let generationRates = measuredResults.map(\.generationTokensPerSecond)
        let minimum = generationRates.min() ?? 0
        let maximum = generationRates.max() ?? 0
        let average = generationRates.reduce(0, +) / Double(max(generationRates.count, 1))
        let median = median(generationRates)

        print("summaryGenerationMin: \(formattedRate(minimum)) tok/s")
        print("summaryGenerationMedian: \(formattedRate(median)) tok/s")
        print("summaryGenerationAverage: \(formattedRate(average)) tok/s")
        print("summaryGenerationMax: \(formattedRate(maximum)) tok/s")

        if let threshold = options.minimumGenerationTokensPerSecond,
           minimum < threshold {
            throw MLXServerMainError.benchmarkThresholdNotMet(
                required: threshold,
                observed: minimum
            )
        }
    }

    private static func runBenchmarkOnce(
        runtime: MLXServerRuntime,
        model: MLXServerModelDescriptor,
        options: MLXServerBenchmarkOptions,
        label: String,
        printsOutput: Bool
    ) async throws -> MLXServerBenchmarkRunResult {
        let request = MLXServerGenerationRequest(
            model: model,
            messages: [
                .user(options.prompt)
            ],
            parameters: model.generationDefaults.generateParameters(
                maxTokens: options.maxTokens,
                temperature: 0
            )
        )
        let stream = try await runtime.generate(request: request)
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
            throw MLXServerMainError.benchmarkMissingMetrics
        }

        print("\(label) promptTokens: \(completionInfo.promptTokenCount)")
        print("\(label) generationTokens: \(completionInfo.generationTokenCount)")
        print("\(label) prefill: \(formattedRate(completionInfo.promptTokensPerSecond)) tok/s")
        print("\(label) generation: \(formattedRate(completionInfo.tokensPerSecond)) tok/s")

        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print("\(label) warning: empty output")
        }

        return MLXServerBenchmarkRunResult(
            promptTokensPerSecond: completionInfo.promptTokensPerSecond,
            generationTokensPerSecond: completionInfo.tokensPerSecond
        )
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

private struct MLXServerBenchmarkOptions {
    var modelID: String?
    var prompt: String
    var maxTokens: Int?
    var quiet: Bool
    var warmupRuns: Int
    var measuredRuns: Int
    var minimumGenerationTokensPerSecond: Double?

    init(arguments: [String]) throws {
        var modelID: String?
        var prompt: String?
        var maxTokens: Int?
        var quiet = false
        var warmupRuns = 0
        var measuredRuns = 1
        var minimumGenerationTokensPerSecond: Double?

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--model":
                modelID = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--prompt":
                prompt = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--max-tokens":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                maxTokens = parsed
            case "--benchmark-warmups":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed >= 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                warmupRuns = parsed
            case "--benchmark-runs":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                measuredRuns = parsed
            case "--min-generation-tokens-per-second":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Double(value), parsed >= 0 else {
                    throw MLXServerMainError.invalidArgument(argument, value)
                }
                minimumGenerationTokensPerSecond = parsed
            case "--quiet":
                quiet = true
            default:
                throw MLXServerMainError.unsupportedArguments([argument])
            }
            index = arguments.index(after: index)
        }

        guard let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MLXServerMainError.missingRequiredArgument("--prompt")
        }

        self.modelID = modelID
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.quiet = quiet
        self.warmupRuns = warmupRuns
        self.measuredRuns = measuredRuns
        self.minimumGenerationTokensPerSecond = minimumGenerationTokensPerSecond
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

private struct MLXServerBenchmarkRunResult {
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double
}

private enum MLXServerMainError: LocalizedError {
    case unsupportedArguments([String])
    case missingRequiredArgument(String)
    case invalidArgument(String, String)
    case benchmarkMissingMetrics
    case benchmarkThresholdNotMet(required: Double, observed: Double)

    var errorDescription: String? {
        switch self {
        case .unsupportedArguments(let arguments):
            return "Unsupported arguments: \(arguments.joined(separator: " ")). Configure mlx-server with mlx-server --setup."
        case .missingRequiredArgument(let argument):
            return "Missing required value for \(argument)."
        case .invalidArgument(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        case .benchmarkMissingMetrics:
            return "Benchmark did not receive MLX completion metrics."
        case .benchmarkThresholdNotMet(let required, let observed):
            return "Benchmark failed: generation \(observed.formatted(.number.precision(.fractionLength(1)))) tok/s is below required \(required.formatted(.number.precision(.fractionLength(1)))) tok/s."
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
      mlx-server
      mlx-server --prompt <text> [--model <id>] [--max-tokens <count>] [--quiet]
                 [--benchmark-warmups <count>] [--benchmark-runs <count>]
                 [--min-generation-tokens-per-second <tok/s>]

    Run mlx-server --setup once to create settings.json. At the end it can launch model setup too.
    Run mlx-server --setup-models directly to create or update models.json and download MLX models.
    Run mlx-server --setup-agents to configure Codex CLI, Codex App, Xcode Codex App, and Xcode Claude Code integrations.
    The server reads runtime settings from settings.json and models only from models.json.
    """
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
