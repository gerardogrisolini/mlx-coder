//
//  MLXServerSetupRunner.swift
//  mlx-server
//

import Foundation
import MLXServerCore
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum MLXServerSetupRunner {
    public static let option = "--setup"

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    public static func run(arguments: [String]) throws -> Bool {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerSetupError.nonInteractiveTerminal
        }

        let settingsURL = MLXServerSettingsStore.settingsURL()
        FileHandle.standardError.writeString(
            """
            mlx-server setup
            Configuring settings.json at:
            \(settingsURL.path)

            """
        )

        var defaultSettings = MLXServerSettings()
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                defaultSettings = try MLXServerSettingsStore.loadRequired(from: settingsURL)
                let shouldReconfigure = try promptYesNo(
                    "settings.json already exists. Reconfigure it?",
                    defaultValue: false
                )
                guard shouldReconfigure else {
                    return try promptConfigureModels()
                }
                FileHandle.standardError.writeString("Using current values as defaults. Press Return to keep them.\n\n")
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        let settings = try buildSettings(defaultSettings: defaultSettings)
        try MLXServerSettingsStore.save(settings, to: settingsURL)
        FileHandle.standardError.writeString("Updated: settings.json\n")
        return try promptConfigureModels()
    }

    private static func promptConfigureModels() throws -> Bool {
        FileHandle.standardError.writeString("\nRuntime setup completed.\n")
        let modelsURL = MLXServerModelsManifestStore.modelsURL()
        return try promptYesNo(
            "Configure models now?",
            defaultValue: !FileManager.default.fileExists(atPath: modelsURL.path)
        )
    }

    private static func buildSettings(defaultSettings: MLXServerSettings) throws -> MLXServerSettings {
        let host = try promptString(
            "Bind host",
            defaultValue: defaultSettings.host,
            allowEmpty: false
        )
        let port = try promptInt(
            "Port",
            defaultValue: defaultSettings.port,
            allowedRange: 1...Int(UInt16.max)
        )
        FileHandle.standardError.writeString(
            "Web server thread suggestion: 2 for local work, at least 4 when used as a server.\n"
        )
        let webServerThreadCount = try promptInt(
            "Thread web server",
            defaultValue: defaultSettings.webServerThreadCount,
            allowedRange: 1...MLXServerSettings.maximumWebServerThreadCount
        )
        let loadOneModelAtATime = try promptYesNo(
            "Load only one model at a time?",
            defaultValue: defaultSettings.loadOneModelAtATime
        )
        let kvCache = try promptKVCacheSettings(
            defaultSettings: defaultSettings.kvCache
        )
        let http2PriorKnowledge = try promptYesNo(
            "Enable HTTP/2 prior knowledge?",
            defaultValue: defaultSettings.http2PriorKnowledge
        )

        let hasTLSSettings = defaultSettings.tlsCertificatePath != nil
            && defaultSettings.tlsPrivateKeyPath != nil
        let configureTLS = try promptYesNo(
            "Configure TLS/SSL?",
            defaultValue: hasTLSSettings
        )
        let tlsCertificatePath: String?
        let tlsPrivateKeyPath: String?
        if configureTLS {
            tlsCertificatePath = try promptString(
                "TLS certificate path",
                defaultValue: defaultSettings.tlsCertificatePath,
                allowEmpty: false,
                maximumLength: MLXServerSetupInputParser.maximumPathLength
            )
            tlsPrivateKeyPath = try promptString(
                "TLS private key path",
                defaultValue: defaultSettings.tlsPrivateKeyPath,
                allowEmpty: false,
                maximumLength: MLXServerSetupInputParser.maximumPathLength
            )
        } else {
            tlsCertificatePath = nil
            tlsPrivateKeyPath = nil
        }

        let useMetricsLogFile = try promptYesNo(
            "Write metrics to a file?",
            defaultValue: defaultSettings.metricsLogPath != nil
        )
        let metricsLogPath: String?
        if useMetricsLogFile {
            metricsLogPath = try promptString(
                "Metrics log file path",
                defaultValue: defaultSettings.metricsLogPath,
                allowEmpty: false,
                maximumLength: MLXServerSetupInputParser.maximumPathLength
            )
        } else {
            metricsLogPath = nil
        }

        let diskKVCacheEnabled = try promptYesNo(
            "Enable disk KV cache?",
            defaultValue: defaultSettings.diskKVCache.enabled
        )
        let diskKVCache: MLXServerDiskKVCacheSettings
        if diskKVCacheEnabled {
            let defaultDirectory = MLXServerDiskKVCacheConfiguration.defaultDirectory().path
            let useCustomDirectory = try promptYesNo(
                "Use a custom KV cache directory?",
                defaultValue: defaultSettings.diskKVCache.directoryPath != nil
            )
            let directoryPath: String?
            if useCustomDirectory {
                directoryPath = try promptString(
                    "KV cache directory",
                    defaultValue: defaultSettings.diskKVCache.directoryPath ?? defaultDirectory,
                    allowEmpty: false,
                    maximumLength: MLXServerSetupInputParser.maximumPathLength
                )
            } else {
                directoryPath = nil
            }
            let limitGB = try promptDouble(
                "Disk KV cache limit in GB",
                defaultValue: defaultSettings.diskKVCache.limitGB ?? 100,
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

        return try MLXServerSettings(
            host: host,
            port: port,
            webServerThreadCount: webServerThreadCount,
            loadOneModelAtATime: loadOneModelAtATime,
            http2PriorKnowledge: http2PriorKnowledge,
            tlsCertificatePath: tlsCertificatePath,
            tlsPrivateKeyPath: tlsPrivateKeyPath,
            metricsLogPath: metricsLogPath,
            kvCache: kvCache,
            diskKVCache: diskKVCache,
            huggingFaceCache: defaultSettings.huggingFaceCache
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

    private static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        maximumLength: Int? = nil
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            FileHandle.standardError.writeString("\(prompt)\(suffix): ")
            guard let line = readLine() else {
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
            FileHandle.standardError.writeString("\(prompt) [\(defaultLabel)]: ")
            guard let line = readLine() else {
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
        #if os(macOS) || os(Linux)
        return isatty(STDIN_FILENO) == 1
        #else
        return true
        #endif
    }
}

enum MLXServerSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-server --setup requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-server setup."
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
