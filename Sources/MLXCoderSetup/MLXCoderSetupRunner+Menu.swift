//
//  MLXCoderSetupRunner+Menu.swift
//  mlx-coder
//

import Foundation
import MLXCoderCore

extension MLXCoderSetupRunner {
    static func promptSetupSection(
        currentManifest manifest: AgentSettingsManifest?,
        additionalSectionGroups: [MLXCoderSetupAdditionalSectionGroup]
    ) throws -> SetupSection {
        while true {
            let options = setupSectionOptions(
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
            let defaultSection: SetupSection = manifest?.models.isEmpty == false ? .finish : .providersAndModels
            let defaultIndex = options.firstIndex { $0.section == defaultSection } ?? 0

            AgentOutput.standardError.writeString("Setup sections:\n")
            for (index, option) in options.enumerated() {
                let marker = index == defaultIndex ? " *" : ""
                let detail = option.detail.map { " - \($0)" } ?? ""
                AgentOutput.standardError.writeString(
                    "  \(index + 1). \(option.section.title)\(detail)\(marker)\n"
                )
            }

            let value = try promptString(
                "Section",
                defaultValue: String(defaultIndex + 1),
                allowEmpty: false
            )
            let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let selectedSection: SetupSection?
            if let index = Int(normalizedValue),
               options.indices.contains(index - 1) {
                selectedSection = options[index - 1].section
            } else {
                selectedSection = options.first { option in
                    option.section.matches(normalizedValue)
                }?.section
            }

            guard let selectedSection else {
                throw MLXCoderSetupError.invalidChoice(value)
            }
            if selectedSection.requiresConfiguredModels,
               manifest?.models.isEmpty != false {
                AgentOutput.standardError.writeString(
                    "Configure providers and models before modifying that section.\n\n"
                )
                continue
            }
            return selectedSection
        }
    }

    static func setupSectionOptions(
        currentManifest manifest: AgentSettingsManifest?,
        additionalSectionGroups: [MLXCoderSetupAdditionalSectionGroup]
    ) -> [SetupSectionOption] {
        let groupsAfterAgents = additionalSectionGroupOptions(
            additionalSectionGroups,
            placement: .afterAgents
        )
        let groupsAfterVoice = additionalSectionGroupOptions(
            additionalSectionGroups,
            placement: .afterVoice
        )

        var options = [
            SetupSectionOption(
                section: .providersAndModels,
                detail: providersAndModelsSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .defaultModelSettings,
                detail: defaultModelSettingsSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .agents,
                detail: agentsSetupDetail()
            )
        ]

        options.append(contentsOf: groupsAfterAgents)
        options.append(
            contentsOf: [
                SetupSectionOption(
                    section: .telegram,
                    detail: manifest?.telegram?.isEnabled == true ? "enabled" : "disabled"
                ),
                SetupSectionOption(
                    section: .voice,
                    detail: manifest?.voice?.isConfigured == true ? "enabled" : "disabled"
                )
            ]
        )
        options.append(contentsOf: groupsAfterVoice)
        options.append(SetupSectionOption(section: .finish, detail: nil))
        return options
    }

    static func additionalSectionGroupOptions(
        _ groups: [MLXCoderSetupAdditionalSectionGroup],
        placement: MLXCoderSetupAdditionalSectionGroupPlacement
    ) -> [SetupSectionOption] {
        groups.enumerated().compactMap { index, group in
            guard group.placement == placement else {
                return nil
            }
            return SetupSectionOption(
                section: .additionalGroup(
                    index,
                    title: group.title,
                    aliases: group.aliases
                ),
                detail: group.detail
            )
        }
    }

    static func agentsSetupDetail() -> String {
        let url = AgentProfileStore.agentsManifestURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "not configured"
        }
        guard let agents = try? AgentProfileStore.loadRequired() else {
            return "configured"
        }
        return "\(agents.count) agents"
    }

    static func providersAndModelsSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        let providerCount = manifest?.providers.count ?? 0
        let modelCount = manifest?.models.count ?? 0
        if providerCount == 0 && modelCount == 0 {
            return "not configured"
        }
        return "\(providerCount) providers, \(modelCount) models"
    }

    static func defaultModelSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        guard let manifest,
              !manifest.models.isEmpty else {
            return "requires providers/models"
        }
        if let model = selectedModel(in: manifest) {
            return model.displayTitle
        }
        return "not selected"
    }

    static func defaultThinkingSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        guard let manifest,
              !manifest.models.isEmpty else {
            return "requires providers/models"
        }
        guard let model = selectedModel(in: manifest) else {
            return "requires default model"
        }
        guard model.supportsThinking else {
            return "not supported by selected model"
        }
        let selection = model.thinkingSelection(for: manifest.selectedThinkingSelection)
        return selection?.displayTitle ?? "default"
    }

    static func defaultModelSettingsSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        let modelDetail = defaultModelSetupDetail(manifest)
        let thinkingDetail = defaultThinkingSetupDetail(manifest)
        if modelDetail.hasPrefix("requires") {
            return modelDetail
        }
        return "\(modelDetail), thinking: \(thinkingDetail)"
    }

    static func promptDefaultModelSetupSection(
        currentManifest manifest: AgentSettingsManifest
    ) throws -> SetupSection? {
        let options = [
            SetupSectionOption(
                section: .defaultModel,
                detail: defaultModelSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .defaultThinking,
                detail: defaultThinkingSetupDetail(manifest)
            )
        ]
        return try promptNestedSetupSection(
            title: "Default model",
            options: options,
            defaultIndex: 0
        )
    }

    static func promptNestedSetupSection(
        title: String,
        options: [SetupSectionOption],
        defaultIndex: Int
    ) throws -> SetupSection? {
        let backIndex = options.count + 1
        let defaultValue = options.indices.contains(defaultIndex)
            ? String(defaultIndex + 1)
            : String(backIndex)

        AgentOutput.standardError.writeString("\n\(title):\n")
        for (index, option) in options.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            let detail = option.detail.map { " - \($0)" } ?? ""
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(option.section.title)\(detail)\(marker)\n"
            )
        }
        if defaultValue == String(backIndex) {
            AgentOutput.standardError.writeString("  \(backIndex). Back *\n")
        } else {
            AgentOutput.standardError.writeString("  \(backIndex). Back\n")
        }

        let value = try promptString(
            "Section",
            defaultValue: defaultValue,
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = Int(normalizedValue) {
            if options.indices.contains(index - 1) {
                return options[index - 1].section
            }
            if index == backIndex {
                return nil
            }
        }
        if ["back", "exit", "done", "cancel"].contains(normalizedValue) {
            return nil
        }
        if let option = options.first(where: { $0.section.matches(normalizedValue) }) {
            return option.section
        }
        throw MLXCoderSetupError.invalidChoice(value)
    }

    static func promptAdditionalSetupSection(
        in group: MLXCoderSetupAdditionalSectionGroup
    ) throws -> MLXCoderSetupAdditionalSection? {
        guard !group.sections.isEmpty else {
            return nil
        }

        let backIndex = group.sections.count + 1
        let defaultValue = group.prefersBackDefault ? String(backIndex) : "1"

        AgentOutput.standardError.writeString("\n\(group.title):\n")
        for (index, section) in group.sections.enumerated() {
            let marker = !group.prefersBackDefault && index == 0 ? " *" : ""
            let detail = section.detail.map { " - \($0)" } ?? ""
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(section.title)\(detail)\(marker)\n"
            )
        }
        if group.prefersBackDefault {
            AgentOutput.standardError.writeString("  \(backIndex). Back *\n")
        } else {
            AgentOutput.standardError.writeString("  \(backIndex). Back\n")
        }

        let value = try promptString(
            "Section",
            defaultValue: defaultValue,
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = Int(normalizedValue) {
            if group.sections.indices.contains(index - 1) {
                return group.sections[index - 1]
            }
            if index == backIndex {
                return nil
            }
        }
        if ["back", "exit", "done", "cancel"].contains(normalizedValue) {
            return nil
        }
        if let section = group.sections.first(where: { $0.aliases.contains(normalizedValue) }) {
            return section
        }
        throw MLXCoderSetupError.invalidChoice(value)
    }

}
