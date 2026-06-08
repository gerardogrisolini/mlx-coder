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

    public static func allowedToolNames(from params: [String: Any]) -> Set<String>? {
        for key in allowedToolParameterKeys {
            if let names = allowedToolNames(from: params[key]) {
                return names
            }
        }

        if let config = params["config"] as? [String: Any],
           let names = allowedToolNames(from: config) {
            return names
        }

        return nil
    }

    public static func allowedToolNames(from value: Any?) -> Set<String>? {
        if let names = value as? [String] {
            return expandedAllowedToolNames(from: names)
        }

        if let values = value as? [Any] {
            return expandedAllowedToolNames(
                from: values.compactMap(allowedToolName)
            )
        }

        if let object = value as? [String: Any] {
            for key in allowedToolParameterKeys + ["names", "enabled", "items"] {
                if let names = allowedToolNames(from: object[key]) {
                    return names
                }
            }
            if let name = allowedToolName(object) {
                return expandedAllowedToolNames(from: [name])
            }
            return nil
        }

        return nil
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

    private static let allowedToolParameterKeys = [
        "allowedTools",
        "allowed_tools",
        "toolNames",
        "tool_names",
        "enabledTools",
        "enabled_tools",
        "tools"
    ]

    private static func allowedToolName(_ value: Any) -> String? {
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        }

        guard let object = value as? [String: Any] else {
            return nil
        }

        return stringValue(from: object, keys: [
            "name",
            "tool",
            "toolName",
            "tool_name",
            "id",
            "value"
        ])
    }

    private static func expandedAllowedToolNames(from rawNames: [String]) -> Set<String> {
        let names = rawNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            return []
        }

        let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
        var selectedKeys = Set<String>()
        var allowedToolNames = Set<String>()
        for name in names {
            if name.contains(".") {
                allowedToolNames.insert(name)
                continue
            }

            let matchingKeys = TerminalToolSelectionCatalog.selectionKeys(
                for: name,
                items: items
            )
            if matchingKeys.isEmpty {
                allowedToolNames.insert(name)
            } else {
                selectedKeys.formUnion(matchingKeys)
            }
        }

        allowedToolNames.formUnion(
            TerminalToolSelectionCatalog.allowedToolNames(
                for: selectedKeys,
                items: items
            )
        )
        return allowedToolNames
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
