//
//  MLXCoderSetupRunner+DefaultModel.swift
//  mlx-coder
//

import Foundation
import MLXCoderCore

extension MLXCoderSetupRunner {
    static func configureDefaultModel(
        in manifest: AgentSettingsManifest
    ) throws -> AgentSettingsManifest {
        guard !manifest.models.isEmpty else {
            throw MLXCoderSetupError.noModelsConfigured
        }

        let selectedModelID: String
        if manifest.models.count == 1 {
            selectedModelID = manifest.models[0].id
            AgentOutput.standardError.writeString(
                "Only one model configured: \(manifest.models[0].displayTitle)\n"
            )
        } else {
            selectedModelID = try selectDefaultModel(
                from: manifest.models,
                defaultModelID: manifest.selectedModelID
            )
        }
        let selectedThinkingSelection = setupDefaultThinkingSelection(
            for: manifest.models.first { $0.matches(selectedModelID) },
            existingSelection: manifest.selectedThinkingSelection
        )
        return manifestByUpdatingSelection(
            manifest,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection
        )
    }

    static func configureDefaultThinking(
        in manifest: AgentSettingsManifest
    ) throws -> AgentSettingsManifest {
        guard !manifest.models.isEmpty else {
            throw MLXCoderSetupError.noModelsConfigured
        }

        let selectedModelID = preservedOrFirstSelectedModelID(
            from: manifest.models,
            existingSelectedModelID: manifest.selectedModelID
        )
        guard let model = manifest.models.first(where: { $0.matches(selectedModelID) }) else {
            throw MLXCoderSetupError.noModelsConfigured
        }
        guard model.supportsThinking else {
            AgentOutput.standardError.writeString(
                "The selected model does not support thinking options.\n"
            )
            return manifestByUpdatingSelection(
                manifest,
                selectedModelID: selectedModelID,
                selectedThinkingSelection: nil
            )
        }

        let selectedThinkingSelection = try selectDefaultThinkingSelection(
            for: model,
            existingSelection: manifest.selectedThinkingSelection
        )
        return manifestByUpdatingSelection(
            manifest,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection
        )
    }

    static func manifestByUpdatingSelection(
        _ manifest: AgentSettingsManifest,
        selectedModelID: String?,
        selectedThinkingSelection: AgentThinkingSelection?
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            version: manifest.version,
            providers: manifest.providers,
            models: manifest.models,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection,
            telegram: manifest.telegram,
            voice: manifest.voice,
            remoteAPIKeysByProviderID: manifest.remoteAPIKeysByProviderID,
            localExecAllowedCommands: manifest.localExecAllowedCommands,
            chatGPTSubscriptionCredentials: manifest.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest.anthropicSubscriptionCredentials
        )
    }

    static func selectedModel(
        in manifest: AgentSettingsManifest
    ) -> AgentSettingsModelManifest? {
        guard let selectedModelID = manifest.selectedModelID else {
            return nil
        }
        return manifest.models.first { $0.matches(selectedModelID) }
    }

    static func selectDefaultModel(
        from models: [AgentSettingsModelManifest],
        defaultModelID: String? = nil
    ) throws -> String {
        AgentOutput.standardError.writeString("\nDefault model:\n")
        let defaultIndex = defaultModelID
            .flatMap { selectedID in models.firstIndex { $0.matches(selectedID) } }
            ?? 0
        for (index, model) in models.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            AgentOutput.standardError.writeString("  \(index + 1). \(model.displayTitle)\(marker)\n")
        }
        let value = try promptString(
            "Choice",
            defaultValue: String(defaultIndex + 1),
            allowEmpty: false
        )
        if let index = Int(value),
           models.indices.contains(index - 1) {
            return models[index - 1].id
        }
        if let model = models.first(where: { $0.matches(value) }) {
            return model.id
        }
        throw MLXCoderSetupError.invalidChoice(value)
    }

    static func setupDefaultThinkingSelection(
        for model: AgentSettingsModelManifest?,
        existingSelection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        model?.thinkingSelection(for: existingSelection)
    }

    static func selectDefaultThinkingSelection(
        for model: AgentSettingsModelManifest?,
        existingSelection: AgentThinkingSelection?
    ) throws -> AgentThinkingSelection? {
        guard let model,
              !model.availableThinkingSelections.isEmpty else {
            return nil
        }

        let options = model.availableThinkingSelections
        let defaultSelection = setupDefaultThinkingSelection(
            for: model,
            existingSelection: existingSelection
        )
        let defaultIndex = defaultSelection.flatMap { options.firstIndex(of: $0) } ?? 0

        AgentOutput.standardError.writeString("\nDefault thinking for \(model.displayTitle):\n")
        for (index, option) in options.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(option.menuTitle) [\(option.rawValue)]\(marker)\n"
            )
        }

        let value = try promptString(
            "Choice",
            defaultValue: String(defaultIndex + 1),
            allowEmpty: false
        )
        if let index = Int(value),
           options.indices.contains(index - 1) {
            return options[index - 1]
        }
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let option = options.first(where: { option in
            option.rawValue.lowercased() == normalizedValue
                || option.displayTitle.lowercased() == normalizedValue
                || option.menuTitle.lowercased() == normalizedValue
        }) {
            return option
        }
        throw MLXCoderSetupError.invalidChoice(value)
    }

}
