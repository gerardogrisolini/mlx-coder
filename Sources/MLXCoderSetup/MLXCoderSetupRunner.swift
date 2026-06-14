//
//  MLXCoderSetupRunner.swift
//  mlx-coder
//
//  Created by Codex on 23/05/26.
//

import Foundation
import MLXCoderCore

public enum MLXCoderSetupAdditionalSectionResult {
    case unchanged
    case removedStandaloneConfiguration
}

public struct MLXCoderSetupAdditionalSection {
    let title: String
    let detail: String?
    let aliases: Set<String>
    private let action: () async throws -> MLXCoderSetupAdditionalSectionResult

    public init(
        title: String,
        detail: String? = nil,
        aliases: Set<String> = [],
        action: @escaping () async throws -> MLXCoderSetupAdditionalSectionResult
    ) {
        self.title = title
        self.detail = detail
        self.aliases = aliases
        self.action = action
    }

    func run() async throws -> MLXCoderSetupAdditionalSectionResult {
        try await action()
    }
}

public struct MLXCoderSetupAdditionalSectionGroup {
    let title: String
    let detail: String?
    let aliases: Set<String>
    let placement: MLXCoderSetupAdditionalSectionGroupPlacement
    let prefersBackDefault: Bool
    let sections: [MLXCoderSetupAdditionalSection]

    public init(
        title: String,
        detail: String? = nil,
        aliases: Set<String> = [],
        placement: MLXCoderSetupAdditionalSectionGroupPlacement = .afterAgents,
        prefersBackDefault: Bool = false,
        sections: [MLXCoderSetupAdditionalSection]
    ) {
        self.title = title
        self.detail = detail
        self.aliases = aliases
        self.placement = placement
        self.prefersBackDefault = prefersBackDefault
        self.sections = sections
    }
}

public enum MLXCoderSetupAdditionalSectionGroupPlacement {
    case afterAgents
    case afterVoice
}

public enum MLXCoderSetupRunner {
    static let interactiveLineReader = TerminalInteractiveLineReader()

    public static func run(
        arguments: [String],
        additionalSectionGroups: [MLXCoderSetupAdditionalSectionGroup] = []
    ) async throws {
        _ = arguments
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw MLXCoderSetupError.nonInteractiveTerminal
        }

        AgentOutput.standardError.writeString(
            """
            mlx-coder setup
            Configuring support files at:
            \(MLXCoderSupportFileService.supportDirectoryURL().path)

            """
        )

        let settingsURL = AgentSettingsManifestStore.settingsURL()
        var originalManifest: AgentSettingsManifest?
        var manifest: AgentSettingsManifest?
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                originalManifest = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
                manifest = originalManifest
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

        if manifest == nil {
            AgentOutput.standardError.writeString(
                "No valid settings.json found. Configure providers and models first.\n\n"
            )
        }

        var didChangeSettings = false
        var didRunAdditionalSection = false
        while true {
            let section = try promptSetupSection(
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
            guard section != .finish else {
                break
            }

            let previousManifest = manifest
            let result = try await configureSetupSection(
                section,
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
            if result.additionalResult == .removedStandaloneConfiguration {
                manifest = nil
                originalManifest = nil
                didChangeSettings = false
                didRunAdditionalSection = true
            } else if section.isAdditional {
                manifest = result.manifest
                didRunAdditionalSection = true
            } else if result.manifest != previousManifest {
                manifest = result.manifest
                didChangeSettings = true
            } else {
                manifest = result.manifest
            }

            guard try promptYesNo("Modify another setup section?", defaultValue: false) else {
                break
            }
        }

        guard let finalManifest = manifest else {
            if didRunAdditionalSection {
                printCompletion()
                return
            }
            throw MLXCoderSetupError.noModelsConfigured
        }

        let shouldWriteSettings = didChangeSettings
            || originalManifest == nil
            || finalManifest != originalManifest
        let result = try MLXCoderSupportFileService.ensureRequiredFiles(
            settingsManifest: finalManifest,
            overwriteSettings: shouldWriteSettings
        )
        printResult(result, settingsWasWritten: shouldWriteSettings)
        printCompletion()
    }

    static func printCompletion() {
        AgentOutput.standardError.writeString("\nSetup completed.\n\n")
    }

    static func requireExistingManifest(
        _ manifest: AgentSettingsManifest?
    ) throws -> AgentSettingsManifest {
        guard let manifest else {
            throw MLXCoderSetupError.noModelsConfigured
        }
        return manifest
    }


    static func configureSetupSection(
        _ section: SetupSection,
        currentManifest manifest: AgentSettingsManifest?,
        additionalSectionGroups: [MLXCoderSetupAdditionalSectionGroup]
    ) async throws -> SetupSectionConfigurationResult {
        switch section {
        case .providersAndModels:
            return SetupSectionConfigurationResult(
                manifest: try await configureProvidersAndModels(existingManifest: manifest)
            )
        case .defaultModelSettings:
            guard let nestedSection = try promptDefaultModelSetupSection(
                currentManifest: requireExistingManifest(manifest)
            ) else {
                return SetupSectionConfigurationResult(manifest: manifest)
            }
            return try await configureSetupSection(
                nestedSection,
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
        case .defaultModel:
            return SetupSectionConfigurationResult(
                manifest: try configureDefaultModel(in: requireExistingManifest(manifest))
            )
        case .defaultThinking:
            return SetupSectionConfigurationResult(
                manifest: try configureDefaultThinking(in: requireExistingManifest(manifest))
            )
        case .telegram:
            return SetupSectionConfigurationResult(
                manifest: try await configureTelegram(in: requireExistingManifest(manifest))
            )
        case .voice:
            return SetupSectionConfigurationResult(
                manifest: try configureVoice(in: requireExistingManifest(manifest))
            )
        case .agents:
            try MLXCoderAgentProfileSetupRunner.configureInteractively()
            return SetupSectionConfigurationResult(
                manifest: try requireExistingManifest(manifest)
            )
        case .additionalGroup(let index, _, _):
            guard additionalSectionGroups.indices.contains(index) else {
                throw MLXCoderSetupError.invalidChoice(String(index + 1))
            }
            guard let additionalSection = try promptAdditionalSetupSection(
                in: additionalSectionGroups[index]
            ) else {
                return SetupSectionConfigurationResult(manifest: manifest)
            }
            let result = try await additionalSection.run()
            return SetupSectionConfigurationResult(
                manifest: manifest,
                additionalResult: result
            )
        case .finish:
            return SetupSectionConfigurationResult(manifest: manifest)
        }
    }
}
