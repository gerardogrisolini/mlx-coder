//
//  MLXServerSetupRunner.swift
//  mlx-server
//

import Foundation
import MLXServerCore

public enum MLXServerSetupRunner {
    public static let option = "--setup"
    private static let interactiveLineReader = MLXServerSetupInteractiveLineReader()

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    public static func run(arguments: [String]) throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerSetupError.nonInteractiveTerminal
        }

        let settingsURL = MLXServerSettingsStore.settingsURL()
        let hadSettingsFile = FileManager.default.fileExists(atPath: settingsURL.path)
        FileHandle.standardError.writeString(
            """
            mlx-server setup
            Configuring settings.json at:
            \(settingsURL.path)

            """
        )

        var originalSettings: MLXServerSettings?
        var settings = MLXServerSettings()
        if hadSettingsFile {
            do {
                settings = try MLXServerSettingsStore.loadRequired(from: settingsURL)
                originalSettings = settings
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
                FileHandle.standardError.writeString(
                    "Invalid settings will be replaced with defaults unless you edit a section.\n\n"
                )
            }
        } else {
            FileHandle.standardError.writeString(
                "No settings.json found. Defaults will be used unless you edit a section.\n\n"
            )
        }

        var didChangeSettings = false
        while true {
            let section = try promptSetupSection(
                currentSettings: settings,
                settingsExists: originalSettings != nil
            )
            guard section != .finish else {
                break
            }

            let previousSettings = settings
            settings = try configureSetupSection(section, currentSettings: settings)
            if settings != previousSettings {
                didChangeSettings = true
            }

            guard try promptYesNo("Modify another setup section?", defaultValue: false) else {
                break
            }
        }

        let finalSettings = try settings.validated()
        let shouldWriteSettings = didChangeSettings
            || originalSettings == nil
            || finalSettings != originalSettings
        if shouldWriteSettings {
            try MLXServerSettingsStore.save(finalSettings, to: settingsURL)
            FileHandle.standardError.writeString(
                hadSettingsFile ? "Updated: settings.json\n" : "Created: settings.json\n"
            )
            do {
                try syncActiveHTTPAgentIntegrations(settings: finalSettings)
            } catch {
                FileHandle.standardError.writeString(
                    """
                    Could not update active HTTP agent integrations: \(error.localizedDescription)
                    Run `mlx-server --setup-agents` to refresh them after setup.
                    """
                )
            }
        } else {
            FileHandle.standardError.writeString("Preserved: settings.json\n")
        }
        printRuntimeSetupCompleted()
    }

    private static func printRuntimeSetupCompleted() {
        FileHandle.standardError.writeString("\nRuntime setup completed.\n")
    }

    private static func promptSetupSection(
        currentSettings settings: MLXServerSettings,
        settingsExists: Bool
    ) throws -> SetupSection {
        let options = setupSectionOptions(currentSettings: settings)
        let defaultSection: SetupSection = settingsExists ? .finish : .serverBinding
        let defaultIndex = options.firstIndex { $0.section == defaultSection } ?? 0

        FileHandle.standardError.writeString("Setup sections:\n")
        for (index, option) in options.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            let detail = option.detail.map { " - \($0)" } ?? ""
            FileHandle.standardError.writeString(
                "  \(index + 1). \(option.section.title)\(detail)\(marker)\n"
            )
        }

        let value = try promptString(
            "Section",
            defaultValue: String(defaultIndex + 1),
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = Int(normalizedValue),
           options.indices.contains(index - 1) {
            return options[index - 1].section
        }
        if let option = options.first(where: { $0.section.matches(normalizedValue) }) {
            return option.section
        }
        throw MLXServerSetupError.invalidChoice(value)
    }

    private static func setupSectionOptions(
        currentSettings settings: MLXServerSettings
    ) -> [SetupSectionOption] {
        [
            SetupSectionOption(
                section: .serverBinding,
                detail: "\(settings.host):\(settings.port), threads \(settings.webServerThreadCount)"
            ),
            SetupSectionOption(
                section: .modelLoading,
                detail: settings.loadOneModelAtATime ? "one model at a time" : "keep loaded models"
            ),
            SetupSectionOption(
                section: .kvCache,
                detail: kvCacheSetupDetail(settings.kvCache)
            ),
            SetupSectionOption(
                section: .http2,
                detail: settings.http2PriorKnowledge ? "enabled" : "disabled"
            ),
            SetupSectionOption(
                section: .apiKey,
                detail: settings.apiKey?.nilIfEmpty == nil ? "disabled" : "enabled"
            ),
            SetupSectionOption(
                section: .tls,
                detail: tlsSetupDetail(settings)
            ),
            SetupSectionOption(
                section: .metrics,
                detail: settings.metricsLogPath?.nilIfEmpty == nil ? "disabled" : settings.metricsLogPath
            ),
            SetupSectionOption(
                section: .diskKVCache,
                detail: diskKVCacheSetupDetail(settings.diskKVCache)
            ),
            SetupSectionOption(section: .finish, detail: nil)
        ]
    }

    private static func kvCacheSetupDetail(_ settings: MLXServerKVCacheSettings) -> String {
        let settings = settings.validated()
        if let profile = KVCacheProfile.matching(settings) {
            return profile.title
        }
        switch settings.mode {
        case .standard:
            return "standard"
        case .quantized:
            return "quantized \(settings.quantizedBits)-bit, group \(settings.quantizedGroupSize), start \(settings.quantizedStart)"
        }
    }

    private static func tlsSetupDetail(_ settings: MLXServerSettings) -> String {
        if settings.tlsCertificatePath?.nilIfEmpty != nil,
           settings.tlsPrivateKeyPath?.nilIfEmpty != nil {
            return "enabled"
        }
        return "disabled"
    }

    private static func diskKVCacheSetupDetail(_ settings: MLXServerDiskKVCacheSettings) -> String {
        guard settings.enabled else {
            return "disabled"
        }
        let limit = settings.limitGB.map { String(format: "%.0f GB", $0) } ?? "no limit"
        if let directoryPath = settings.directoryPath?.nilIfEmpty {
            return "enabled, \(limit), \(directoryPath)"
        }
        return "enabled, \(limit), default directory"
    }

    private static func configureSetupSection(
        _ section: SetupSection,
        currentSettings settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        switch section {
        case .serverBinding:
            return try configureServerBinding(settings)
        case .modelLoading:
            return try configureModelLoading(settings)
        case .kvCache:
            return try configureKVCache(settings)
        case .http2:
            return try configureHTTP2(settings)
        case .apiKey:
            return try configureAPIKey(settings)
        case .tls:
            return try configureTLS(settings)
        case .metrics:
            return try configureMetrics(settings)
        case .diskKVCache:
            return try configureDiskKVCache(settings)
        case .finish:
            return settings
        }
    }

    private static func configureServerBinding(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let host = try promptString(
            "Bind host",
            defaultValue: settings.host,
            allowEmpty: false
        )
        let port = try promptInt(
            "Port",
            defaultValue: settings.port,
            allowedRange: 1...Int(UInt16.max)
        )
        FileHandle.standardError.writeString(
            "Web server thread suggestion: 2 for local work, at least 4 when used as a server.\n"
        )
        let webServerThreadCount = try promptInt(
            "Thread web server",
            defaultValue: settings.webServerThreadCount,
            allowedRange: 1...MLXServerSettings.maximumWebServerThreadCount
        )
        return try settingsByUpdating(
            settings,
            host: host,
            port: port,
            webServerThreadCount: webServerThreadCount
        )
    }

    private static func configureModelLoading(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let loadOneModelAtATime = try promptYesNo(
            "Load only one model at a time?",
            defaultValue: settings.loadOneModelAtATime
        )
        return try settingsByUpdating(settings, loadOneModelAtATime: loadOneModelAtATime)
    }

    private static func configureKVCache(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let kvCache = try promptKVCacheSettings(defaultSettings: settings.kvCache)
        return try settingsByUpdating(settings, kvCache: kvCache)
    }

    private static func configureHTTP2(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let http2PriorKnowledge = try promptYesNo(
            "Enable HTTP/2 prior knowledge?",
            defaultValue: settings.http2PriorKnowledge
        )
        return try settingsByUpdating(settings, http2PriorKnowledge: http2PriorKnowledge)
    }

    private static func configureAPIKey(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let apiKey = try promptAPIKey(defaultValue: settings.apiKey)
        return try settingsByUpdating(settings, apiKey: apiKey)
    }

    private static func configureTLS(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let hasTLSSettings = settings.tlsCertificatePath != nil
            && settings.tlsPrivateKeyPath != nil
        let configureTLS = try promptYesNo(
            "Configure TLS/SSL?",
            defaultValue: hasTLSSettings
        )
        let tlsCertificatePath: String?
        let tlsPrivateKeyPath: String?
        if configureTLS {
            tlsCertificatePath = try promptString(
                "TLS certificate path",
                defaultValue: settings.tlsCertificatePath,
                allowEmpty: false,
                maximumLength: MLXServerSetupInputParser.maximumPathLength
            )
            tlsPrivateKeyPath = try promptString(
                "TLS private key path",
                defaultValue: settings.tlsPrivateKeyPath,
                allowEmpty: false,
                maximumLength: MLXServerSetupInputParser.maximumPathLength
            )
        } else {
            tlsCertificatePath = nil
            tlsPrivateKeyPath = nil
        }
        return try settingsByUpdating(
            settings,
            tlsCertificatePath: tlsCertificatePath,
            tlsPrivateKeyPath: tlsPrivateKeyPath
        )
    }

    private static func configureMetrics(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let useMetricsLogFile = try promptYesNo(
            "Write metrics to a file?",
            defaultValue: settings.metricsLogPath != nil
        )
        let metricsLogPath: String?
        if useMetricsLogFile {
            metricsLogPath = try promptString(
                "Metrics log file path",
                defaultValue: settings.metricsLogPath,
                allowEmpty: false,
                maximumLength: MLXServerSetupInputParser.maximumPathLength
            )
        } else {
            metricsLogPath = nil
        }
        return try settingsByUpdating(settings, metricsLogPath: metricsLogPath)
    }

    private static func configureDiskKVCache(
        _ settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        let diskKVCacheEnabled = try promptYesNo(
            "Enable disk KV cache?",
            defaultValue: settings.diskKVCache.enabled
        )
        let diskKVCache: MLXServerDiskKVCacheSettings
        if diskKVCacheEnabled {
            let defaultDirectory = MLXServerDiskKVCacheConfiguration.defaultDirectory().path
            let useCustomDirectory = try promptYesNo(
                "Use a custom KV cache directory?",
                defaultValue: settings.diskKVCache.directoryPath != nil
            )
            let directoryPath: String?
            if useCustomDirectory {
                directoryPath = try promptString(
                    "KV cache directory",
                    defaultValue: settings.diskKVCache.directoryPath ?? defaultDirectory,
                    allowEmpty: false,
                    maximumLength: MLXServerSetupInputParser.maximumPathLength
                )
            } else {
                directoryPath = nil
            }
            let limitGB = try promptDouble(
                "Disk KV cache limit in GB",
                defaultValue: settings.diskKVCache.limitGB ?? 100,
                allowedRange: 0...MLXServerDiskKVCacheSettings.maximumLimitGB
            )
            diskKVCache = MLXServerDiskKVCacheSettings(
                enabled: true,
                directoryPath: directoryPath,
                limitGB: limitGB
            )
        } else {
            diskKVCache = MLXServerDiskKVCacheSettings(enabled: false)
        }
        return try settingsByUpdating(settings, diskKVCache: diskKVCache)
    }

    private static func settingsByUpdating(
        _ settings: MLXServerSettings,
        host: String? = nil,
        port: Int? = nil,
        webServerThreadCount: Int? = nil,
        loadOneModelAtATime: Bool? = nil,
        http2PriorKnowledge: Bool? = nil,
        apiKey: String?? = nil,
        tlsCertificatePath: String?? = nil,
        tlsPrivateKeyPath: String?? = nil,
        metricsLogPath: String?? = nil,
        kvCache: MLXServerKVCacheSettings? = nil,
        diskKVCache: MLXServerDiskKVCacheSettings? = nil
    ) throws -> MLXServerSettings {
        try MLXServerSettings(
            host: host ?? settings.host,
            port: port ?? settings.port,
            webServerThreadCount: webServerThreadCount ?? settings.webServerThreadCount,
            loadOneModelAtATime: loadOneModelAtATime ?? settings.loadOneModelAtATime,
            http2PriorKnowledge: http2PriorKnowledge ?? settings.http2PriorKnowledge,
            apiKey: apiKey ?? settings.apiKey,
            tlsCertificatePath: tlsCertificatePath ?? settings.tlsCertificatePath,
            tlsPrivateKeyPath: tlsPrivateKeyPath ?? settings.tlsPrivateKeyPath,
            metricsLogPath: metricsLogPath ?? settings.metricsLogPath,
            kvCache: kvCache ?? settings.kvCache,
            diskKVCache: diskKVCache ?? settings.diskKVCache,
            huggingFaceCache: settings.huggingFaceCache
        ).validated()
    }

    private static func promptKVCacheSettings(
        defaultSettings: MLXServerKVCacheSettings
    ) throws -> MLXServerKVCacheSettings {
        FileHandle.standardError.writeString(
            """

            In-memory KV cache:
              1. Best Performance - standard full precision cache
              2. Balanced - quantized after 1024 tokens
              3. Low Memory - quantized immediately
              4. Long Sessions - quantized after 2048 tokens
              5. Custom - manually set mode, bits, group size, and start

            """
        )

        let defaultProfile = KVCacheProfile.matching(defaultSettings.validated()) ?? .custom
        let selectedProfile = try promptInt(
            "KV cache profile",
            defaultValue: defaultProfile.rawValue,
            allowedRange: KVCacheProfile.allowedRange
        )

        guard let profile = KVCacheProfile(rawValue: selectedProfile) else {
            return defaultSettings.validated()
        }

        switch profile {
        case .bestPerformance, .balanced, .lowMemory, .longSessions:
            return profile.presetSettings ?? defaultSettings.validated()
        case .custom:
            let useQuantized = try promptYesNo(
                "Use quantized KV cache?",
                defaultValue: defaultSettings.mode == .quantized
            )
            guard useQuantized else {
                return MLXServerKVCacheSettings(
                    mode: .standard,
                    quantizedBits: defaultSettings.quantizedBits,
                    quantizedGroupSize: defaultSettings.quantizedGroupSize,
                    quantizedStart: defaultSettings.quantizedStart
                ).validated()
            }

            let quantizedBits = try promptInt(
                "KV quantized bits",
                defaultValue: defaultSettings.quantizedBits,
                allowedRange: 2...8
            )
            let quantizedGroupSize = try promptInt(
                "KV quantized group size",
                defaultValue: defaultSettings.quantizedGroupSize,
                allowedRange: 1...256
            )
            let quantizedStart = try promptInt(
                "Quantized start token",
                defaultValue: defaultSettings.quantizedStart,
                allowedRange: 0...262_144
            )
            return MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedBits: quantizedBits,
                quantizedGroupSize: quantizedGroupSize,
                quantizedStart: quantizedStart
            ).validated()
        }
    }

    private static func promptAPIKey(defaultValue: String?) throws -> String? {
        let existingAPIKey = defaultValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if existingAPIKey != nil {
            let keepExisting = try promptYesNo(
                "Keep existing API key?",
                defaultValue: true
            )
            if keepExisting {
                return existingAPIKey
            }
        }

        let requireAPIKey = try promptYesNo(
            "Require an API key for HTTP clients?",
            defaultValue: existingAPIKey != nil
        )
        guard requireAPIKey else {
            return nil
        }
        return try promptString(
            "API key",
            defaultValue: nil,
            allowEmpty: false,
            isSecure: true
        )
    }

    private static func syncActiveHTTPAgentIntegrations(settings: MLXServerSettings) throws {
        guard let manifest = try? MLXServerModelsManifestStore.loadRequired().validated() else {
            return
        }
        let enabledModels = manifest.models.filter(\.enabled)
        guard let defaultModel = enabledModels.first(where: { $0.id == manifest.defaultModelID }) else {
            return
        }

        let status = MLXServerAgentIntegrationService.status()
        guard status.codexCLIEnabled
            || status.codexAppEnabled
            || status.codexXcodeAppEnabled
            || status.xcodeClaudeCodeEnabled else {
            return
        }

        let configuration = MLXServerAgentIntegrationConfiguration(
            baseURL: MLXServerAgentIntegrationService.defaultServerBaseURL(),
            modelID: defaultModel.id,
            contextWindow: defaultModel.generationDefaults.contextWindow,
            apiKey: settings.apiKey
        )

        if status.codexCLIEnabled {
            try MLXServerAgentIntegrationService.configureCodexCLIProfile(
                configuration: configuration
            )
        }
        if status.codexAppEnabled {
            try MLXServerAgentIntegrationService.configureCodexAppProfile(
                target: .desktop,
                configuration: configuration
            )
        }
        if status.codexXcodeAppEnabled {
            try MLXServerAgentIntegrationService.configureCodexAppProfile(
                target: .xcode,
                configuration: configuration
            )
        }
        if status.xcodeClaudeCodeEnabled {
            try MLXServerAgentIntegrationService.configureXcodeClaudeCode(
                configuration: configuration
            )
        }

        FileHandle.standardError.writeString("Updated active HTTP agent integrations.\n")
    }

    private static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        maximumLength: Int? = nil,
        isSecure: Bool = false
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            let linePrompt = "\(prompt)\(suffix): "
            let line = isSecure
                ? interactiveLineReader.readSecureLine(prompt: linePrompt)
                : interactiveLineReader.readLine(prompt: linePrompt)
            guard let line else {
                throw MLXServerSetupError.inputClosed
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, let defaultValue {
                return defaultValue
            }
            if trimmed.isEmpty, allowEmpty {
                return ""
            }
            if !MLXServerSetupInputParser.isValidLength(trimmed, maximumLength: maximumLength) {
                FileHandle.standardError.writeString(
                    "Invalid value: maximum length is \(maximumLength ?? 0) characters.\n"
                )
                continue
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
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptDouble(
        _ prompt: String,
        defaultValue: Double,
        allowedRange: ClosedRange<Double>
    ) throws -> Double {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(format: "%.0f", defaultValue),
                allowEmpty: false
            )
            guard let parsed = MLXServerSetupInputParser.parseDouble(value),
                  allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    private static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt) [\(defaultLabel)]: ") else {
                throw MLXServerSetupError.inputClosed
            }
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                return defaultValue
            }
            if ["y", "yes"].contains(normalized) {
                return true
            }
            if ["n", "no"].contains(normalized) {
                return false
            }
        }
    }

    private static func supportsInteractiveInput() -> Bool {
        MLXServerSetupInteractiveLineReader.supportsInteractiveInput()
    }
}

private struct SetupSectionOption {
    let section: SetupSection
    let detail: String?
}

private enum SetupSection: Equatable {
    case serverBinding
    case modelLoading
    case kvCache
    case http2
    case apiKey
    case tls
    case metrics
    case diskKVCache
    case finish

    var title: String {
        switch self {
        case .serverBinding:
            return "Host, port, and web server threads"
        case .modelLoading:
            return "Model loading policy"
        case .kvCache:
            return "In-memory KV cache"
        case .http2:
            return "HTTP/2 prior knowledge"
        case .apiKey:
            return "HTTP API key"
        case .tls:
            return "TLS/SSL"
        case .metrics:
            return "Metrics log file"
        case .diskKVCache:
            return "Disk KV cache"
        case .finish:
            return "Finish setup"
        }
    }

    func matches(_ value: String) -> Bool {
        aliases.contains(value)
    }

    private var aliases: Set<String> {
        switch self {
        case .serverBinding:
            return ["host", "port", "threads", "thread", "server", "binding", "bind"]
        case .modelLoading:
            return ["models", "model loading", "loading", "load", "retention"]
        case .kvCache:
            return ["kv", "kv cache", "memory kv", "in-memory kv cache", "cache"]
        case .http2:
            return ["http2", "http/2", "h2", "prior knowledge"]
        case .apiKey:
            return ["api", "api key", "key", "authentication", "auth"]
        case .tls:
            return ["tls", "ssl", "https", "certificate"]
        case .metrics:
            return ["metrics", "metrics log", "log"]
        case .diskKVCache:
            return ["disk", "disk kv", "disk kv cache", "persistent kv"]
        case .finish:
            return ["finish", "done", "exit", "quit", "end", "stop"]
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

enum MLXServerSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed
    case invalidChoice(String)

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-server --setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-server setup."
        case let .invalidChoice(value):
            return "Invalid setup choice: \(value)"
        }
    }
}

private enum KVCacheProfile: Int, CaseIterable {
    case bestPerformance = 1
    case balanced = 2
    case lowMemory = 3
    case longSessions = 4
    case custom = 5

    static var allowedRange: ClosedRange<Int> {
        guard let first = allCases.first?.rawValue,
              let last = allCases.last?.rawValue else {
            return 1...1
        }
        return first...last
    }

    static func matching(_ settings: MLXServerKVCacheSettings) -> Self? {
        allCases.first { $0.presetSettings == settings }
    }

    var title: String {
        switch self {
        case .bestPerformance:
            return "Best Performance"
        case .balanced:
            return "Balanced"
        case .lowMemory:
            return "Low Memory"
        case .longSessions:
            return "Long Sessions"
        case .custom:
            return "Custom"
        }
    }

    var presetSettings: MLXServerKVCacheSettings? {
        switch self {
        case .bestPerformance:
            MLXServerKVCacheSettings(mode: .standard)
        case .balanced:
            MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedStart: 1_024
            )
        case .lowMemory:
            MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedStart: 0
            )
        case .longSessions:
            MLXServerKVCacheSettings(
                mode: .quantized,
                quantizedStart: 2_048
            )
        case .custom:
            nil
        }
    }
}

enum MLXServerSetupInputParser {
    static let maximumPathLength = 4_096

    static func parseDouble(_ value: String) -> Double? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let decimalSeparatorCount = trimmed.reduce(into: 0) { count, character in
            if character == "." || character == "," {
                count += 1
            }
        }
        guard decimalSeparatorCount <= 1 else {
            return nil
        }

        let normalized = trimmed.replacingOccurrences(of: ",", with: ".", options: .literal)
        guard let parsed = Double(normalized), parsed.isFinite else {
            return nil
        }
        return parsed
    }

    static func isValidLength(_ value: String, maximumLength: Int?) -> Bool {
        guard let maximumLength else {
            return true
        }
        return value.count <= maximumLength
    }
}
