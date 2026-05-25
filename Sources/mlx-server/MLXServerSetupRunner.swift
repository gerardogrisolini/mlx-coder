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

enum MLXServerSetupRunner {
    static let option = "--setup"

    static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    static func run(arguments: [String]) throws -> Bool {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerSetupError.nonInteractiveTerminal
        }

        let settingsURL = MLXServerSettingsStore.settingsURL()
        FileHandle.standardError.writeString(
            """
            mlx-server setup
            Configuro settings.json in:
            \(settingsURL.path)

            """
        )

        var defaultSettings = MLXServerSettings()
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                defaultSettings = try MLXServerSettingsStore.loadRequired(from: settingsURL)
                let shouldReconfigure = try promptYesNo(
                    "settings.json esiste gia. Vuoi riconfigurarlo?",
                    defaultValue: false
                )
                guard shouldReconfigure else {
                    return try promptConfigureModels()
                }
                FileHandle.standardError.writeString("Uso i valori attuali come default. Premi invio per mantenerli.\n\n")
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "settings.json esiste ma non e valido. Vuoi riscriverlo?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        let settings = try buildSettings(defaultSettings: defaultSettings)
        try MLXServerSettingsStore.save(settings, to: settingsURL)
        FileHandle.standardError.writeString("Aggiornato: settings.json\n")
        return try promptConfigureModels()
    }

    private static func promptConfigureModels() throws -> Bool {
        FileHandle.standardError.writeString("\nSetup runtime completato.\n")
        let modelsURL = MLXServerModelsManifestStore.modelsURL()
        return try promptYesNo(
            "Vuoi configurare anche i modelli?",
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
            "Porta",
            defaultValue: defaultSettings.port,
            allowedRange: 1...Int(UInt16.max)
        )
        let loadOneModelAtATime = try promptYesNo(
            "Caricare un solo modello alla volta?",
            defaultValue: defaultSettings.loadOneModelAtATime
        )
        let http2PriorKnowledge = try promptYesNo(
            "Abilitare HTTP/2 prior knowledge?",
            defaultValue: defaultSettings.http2PriorKnowledge
        )

        let hasTLSSettings = defaultSettings.tlsCertificatePath != nil
            && defaultSettings.tlsPrivateKeyPath != nil
        let configureTLS = try promptYesNo(
            "Configurare TLS/SSL?",
            defaultValue: hasTLSSettings
        )
        let tlsCertificatePath: String?
        let tlsPrivateKeyPath: String?
        if configureTLS {
            tlsCertificatePath = try promptString(
                "Percorso certificato TLS",
                defaultValue: defaultSettings.tlsCertificatePath,
                allowEmpty: false
            )
            tlsPrivateKeyPath = try promptString(
                "Percorso chiave privata TLS",
                defaultValue: defaultSettings.tlsPrivateKeyPath,
                allowEmpty: false
            )
        } else {
            tlsCertificatePath = nil
            tlsPrivateKeyPath = nil
        }

        let useMetricsLogFile = try promptYesNo(
            "Scrivere metriche su file?",
            defaultValue: defaultSettings.metricsLogPath != nil
        )
        let metricsLogPath: String?
        if useMetricsLogFile {
            metricsLogPath = try promptString(
                "Percorso file log metriche",
                defaultValue: defaultSettings.metricsLogPath,
                allowEmpty: false
            )
        } else {
            metricsLogPath = nil
        }

        let diskKVCacheEnabled = try promptYesNo(
            "Abilitare KV cache su disco?",
            defaultValue: defaultSettings.diskKVCache.enabled
        )
        let diskKVCache: MLXServerDiskKVCacheSettings
        if diskKVCacheEnabled {
            let defaultDirectory = MLXServerDiskKVCacheConfiguration.defaultDirectory().path
            let useCustomDirectory = try promptYesNo(
                "Usare una cartella KV cache personalizzata?",
                defaultValue: defaultSettings.diskKVCache.directoryPath != nil
            )
            let directoryPath: String?
            if useCustomDirectory {
                directoryPath = try promptString(
                    "Cartella KV cache",
                    defaultValue: defaultSettings.diskKVCache.directoryPath ?? defaultDirectory,
                    allowEmpty: false
                )
            } else {
                directoryPath = nil
            }
            let limitGB = try promptDouble(
                "Limite KV cache su disco in GB",
                defaultValue: defaultSettings.diskKVCache.limitGB ?? 100,
                allowedRange: 0...Double.greatestFiniteMagnitude
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
            loadOneModelAtATime: loadOneModelAtATime,
            http2PriorKnowledge: http2PriorKnowledge,
            tlsCertificatePath: tlsCertificatePath,
            tlsPrivateKeyPath: tlsPrivateKeyPath,
            metricsLogPath: metricsLogPath,
            diskKVCache: diskKVCache
        ).validated()
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
                throw MLXServerSetupError.inputClosed
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
            guard let parsed = Double(value.replacingOccurrences(of: ",", with: ".")),
                  allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Valore non valido.\n")
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
