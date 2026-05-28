//
//  MLXServerAgentSetupRunner.swift
//  mlx-server
//

import Foundation
import MLXServerCore
#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum MLXServerAgentSetupRunner {
    public static let option = "--join-agents"

    public static func shouldRunSetup(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    public static func argumentsAfterRemovingSetup(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    public static func run(arguments: [String]) throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerAgentSetupError.nonInteractiveTerminal
        }

        let status = MLXServerAgentIntegrationService.status()
        FileHandle.standardError.writeString(
            """
            mlx-server agent setup

            Current status:
            - Codex CLI: \(enabledLabel(status.codexCLIEnabled))
            - Codex App: \(enabledLabel(status.codexAppEnabled))
            - Codex App in Xcode: \(enabledLabel(status.codexXcodeAppEnabled))
            - Claude Code in Xcode: \(enabledLabel(status.xcodeClaudeCodeEnabled))

            """
        )

        let desiredCodexCLI = try promptYesNo(
            "Enable Codex CLI?",
            defaultValue: status.codexCLIEnabled
        )
        let desiredCodexApp = try promptYesNo(
            "Enable Codex App?",
            defaultValue: status.codexAppEnabled
        )
        let desiredCodexXcodeApp = try promptYesNo(
            "Enable Codex App in Xcode?",
            defaultValue: status.codexXcodeAppEnabled
        )
        let desiredXcodeClaudeCode = try promptYesNo(
            "Enable Claude Code in Xcode?",
            defaultValue: status.xcodeClaudeCodeEnabled
        )

        let needsConfiguration = desiredCodexCLI
            || desiredCodexApp
            || desiredCodexXcodeApp
            || desiredXcodeClaudeCode
        let configuration: MLXServerAgentIntegrationConfiguration?
        if needsConfiguration {
            configuration = try promptIntegrationConfiguration()
        } else {
            configuration = nil
        }

        try applyDisabledIntegrations(
            codexCLI: desiredCodexCLI,
            codexApp: desiredCodexApp,
            codexXcodeApp: desiredCodexXcodeApp,
            xcodeClaudeCode: desiredXcodeClaudeCode
        )

        if let configuration {
            try applyEnabledIntegrations(
                codexCLI: desiredCodexCLI,
                codexApp: desiredCodexApp,
                codexXcodeApp: desiredCodexXcodeApp,
                xcodeClaudeCode: desiredXcodeClaudeCode,
                configuration: configuration
            )
        }

        FileHandle.standardError.writeString("\nAgent integration setup completed.\n\n")
    }

    private static func promptIntegrationConfiguration()
        throws -> MLXServerAgentIntegrationConfiguration {
        let defaultBaseURL = defaultServerBaseURL()
        let baseURL = try promptString(
            "Base URL mlx-server",
            defaultValue: defaultBaseURL,
            allowEmpty: false
        )
        let modelSelection = try promptModelSelection()
        return MLXServerAgentIntegrationConfiguration(
            baseURL: baseURL,
            modelID: modelSelection.modelID,
            contextWindow: modelSelection.contextWindow
        )
    }

    private static func applyDisabledIntegrations(
        codexCLI: Bool,
        codexApp: Bool,
        codexXcodeApp: Bool,
        xcodeClaudeCode: Bool
    ) throws {
        if !codexCLI {
            try MLXServerAgentIntegrationService.removeCodexCLIProfile()
        }
        if !codexApp {
            try MLXServerAgentIntegrationService.removeCodexAppProfile(target: .desktop)
        }
        if !codexXcodeApp {
            try MLXServerAgentIntegrationService.removeCodexAppProfile(target: .xcode)
        }
        if !xcodeClaudeCode {
            try MLXServerAgentIntegrationService.removeXcodeClaudeCode()
        }
    }

    private static func applyEnabledIntegrations(
        codexCLI: Bool,
        codexApp: Bool,
        codexXcodeApp: Bool,
        xcodeClaudeCode: Bool,
        configuration: MLXServerAgentIntegrationConfiguration
    ) throws {
        if codexCLI {
            try MLXServerAgentIntegrationService.configureCodexCLIProfile(
                configuration: configuration
            )
            FileHandle.standardError.writeString("Updated: Codex CLI\n")
        }
        if codexApp {
            try MLXServerAgentIntegrationService.configureCodexAppProfile(
                target: .desktop,
                configuration: configuration
            )
            FileHandle.standardError.writeString("Updated: Codex App\n")
        }
        if codexXcodeApp {
            try MLXServerAgentIntegrationService.configureCodexAppProfile(
                target: .xcode,
                configuration: configuration
            )
            FileHandle.standardError.writeString("Updated: Codex App in Xcode\n")
        }
        if xcodeClaudeCode {
            try MLXServerAgentIntegrationService.configureXcodeClaudeCode(
                configuration: configuration
            )
            FileHandle.standardError.writeString("Updated: Claude Code in Xcode\n")
        }
    }

    private static func defaultServerBaseURL() -> String {
        let settings = (try? MLXServerSettingsStore.loadRequired()) ?? MLXServerSettings()
        let scheme = settings.tlsCertificatePath == nil ? "http" : "https"
        return "\(scheme)://\(settings.host):\(settings.port)"
    }

    private static func promptModelSelection() throws -> ModelSelection {
        guard let manifest = try? MLXServerModelsManifestStore.loadRequired().validated() else {
            let modelID = try promptString(
                "Agent model",
                defaultValue: nil,
                allowEmpty: false
            )
            return ModelSelection(modelID: modelID, contextWindow: nil)
        }

        let enabledModels = manifest.models.filter(\.enabled)
        guard !enabledModels.isEmpty else {
            let modelID = try promptString(
                "Agent model",
                defaultValue: nil,
                allowEmpty: false
            )
            return ModelSelection(modelID: modelID, contextWindow: nil)
        }

        let defaultModel = enabledModels.first { $0.id == manifest.defaultModelID }
            ?? enabledModels[0]
        FileHandle.standardError.writeString("\nConfigured models:\n")
        for (index, model) in enabledModels.enumerated() {
            let marker = model.id == defaultModel.id ? " *" : ""
            FileHandle.standardError.writeString("\(index + 1). \(model.id)\(marker)\n")
        }
        FileHandle.standardError.writeString("\n")

        while true {
            let answer = try promptString(
                "Agent model",
                defaultValue: defaultModel.id,
                allowEmpty: false
            )
            if let index = Int(answer),
               enabledModels.indices.contains(index - 1) {
                return ModelSelection(record: enabledModels[index - 1])
            }
            if let record = enabledModels.first(where: { $0.id == answer }) {
                return ModelSelection(record: record)
            }
            if !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ModelSelection(modelID: answer, contextWindow: nil)
            }
        }
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
                throw MLXServerAgentSetupError.inputClosed
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

    private static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            FileHandle.standardError.writeString("\(prompt) [\(defaultLabel)]: ")
            guard let line = readLine() else {
                throw MLXServerAgentSetupError.inputClosed
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

    private static func enabledLabel(_ isEnabled: Bool) -> String {
        isEnabled ? "enabled" : "disabled"
    }
}

private struct ModelSelection {
    var modelID: String
    var contextWindow: Int?

    init(modelID: String, contextWindow: Int?) {
        self.modelID = modelID
        self.contextWindow = contextWindow
    }

    init(record: MLXServerModelRecord) {
        self.modelID = record.id
        self.contextWindow = record.generationDefaults.contextWindow
    }
}

enum MLXServerAgentSetupError: LocalizedError {
    case nonInteractiveTerminal
    case inputClosed

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "mlx-server --join-agents requires an interactive terminal."
        case .inputClosed:
            return "Input closed during mlx-server agent setup."
        }
    }
}
