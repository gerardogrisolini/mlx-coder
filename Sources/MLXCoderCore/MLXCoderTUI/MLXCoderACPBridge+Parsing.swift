//
//  Generated split from MLXCoderACPBridge.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension MLXCoderACPBridge {
    public func runtimeHistory(from value: Any?) -> [AgentRuntimeMessage] {
        guard let messages = value as? [[String: Any]] else {
            return []
        }

        return messages.compactMap { object in
            let rawRole = (object["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let content = (object["content"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty,
                  let role = AgentRuntimeMessage.Role(rawValue: rawRole) else {
                return nil
            }
            return AgentRuntimeMessage(role: role, content: content)
        }
    }

    public static func workingDirectory(from params: [String: Any]) -> String? {
        stringValue(from: params, keys: [
            "cwd",
            "workingDirectory",
            "working_directory",
            "workspace",
            "workspacePath",
            "workspace_path"
        ])
    }

    public static func allowedToolNames(from value: Any?) -> Set<String>? {
        guard let names = value as? [String] else {
            return nil
        }

        return Set(
            names
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    public static func thinkingSelection(from value: Any?) -> AgentThinkingSelection? {
        guard let rawValue = (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawValue.isEmpty else {
            return nil
        }
        return AgentThinkingSelection(rawValue: rawValue)
    }

    private static func stringValue(
        from params: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = (params[key] as? String)?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    public func resolvedSystemPrompt(
        providedSystemPrompt: String?,
        cwd: String,
        allowedToolNames: Set<String>?
    ) -> String {
        let memoryToolEnabled = Self.memoryToolEnabled(allowedToolNames)
        let selectedAgentSection = configuration.selectedAgent?.promptSection(memoryToolEnabled: memoryToolEnabled)
        let selectedSkillSection = selectedAgentSkillSection()
        let providedSystemPrompt = providedSystemPrompt?.nilIfBlank

        if let providedSystemPrompt {
            return [
                MLXSystemPromptBuilder.responseLanguageSection,
                selectedAgentSection,
                selectedSkillSection,
                providedSystemPrompt
            ]
                .compactMap { $0?.nilIfBlank }
                .joined(separator: "\n\n")
        }

        return AgentStandaloneSystemPrompt.prompt(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled,
            selectedAgentSection: selectedAgentSection,
            selectedSkillSection: selectedSkillSection
        )
    }

    public func selectedAgentSkillSection() -> String? {
        guard let selectedAgent = configuration.selectedAgent,
              !selectedAgent.skills.isEmpty else {
            return nil
        }

        let availableSkills = MLXPromptSkillCatalog.discoverSkills(
            searchRoots: MLXPromptSkillCatalog.appCatalogSearchRoots()
        )
        let selectedSkillIDs = selectedAgent.selectedSkillIDs(
            availableSkills: availableSkills
        )
        let selectedSkills = availableSkills.filter { selectedSkillIDs.contains($0.id) }
        return MLXSystemPromptBuilder.selectedSkillSection(skills: selectedSkills)
    }

}
