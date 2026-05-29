//
//  AgentToolSelection.swift
//  MLXCoder
//

import Foundation

public enum AgentToolSelection {
    public static var defaultGroups: Set<TerminalToolGroup> {
        Set(TerminalToolGroup.allCases)
    }

    public static func groups(from rawToolNames: [String]) -> Set<TerminalToolGroup> {
        Set(rawToolNames.compactMap(group(from:)))
    }

    public static func group(from rawToolName: String) -> TerminalToolGroup? {
        let normalizedToolName = rawToolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedToolName.isEmpty else {
            return nil
        }
        if let namedGroup = TerminalToolGroup.group(named: normalizedToolName) {
            return namedGroup
        }
        return TerminalToolGroup.allCases.first { group in
            group.allows(toolName: normalizedToolName)
        }
    }

    public static func allowedToolNames(
        for selectedGroups: Set<TerminalToolGroup>,
        additionalDescriptors: [DirectToolDescriptor] = [],
        includeDynamicGroupPrefixes: Bool = true
    ) -> Set<String> {
        guard !selectedGroups.isEmpty else {
            return []
        }

        var toolNames = Set(
            (DirectToolCatalog.baseDescriptors + additionalDescriptors)
                .map(\.name)
                .filter { toolName in
                    selectedGroups.contains { $0.allows(toolName: toolName) }
                }
        )

        if includeDynamicGroupPrefixes {
            toolNames.formUnion(dynamicToolPrefixes(for: selectedGroups))
        }

        return toolNames
    }

    public static func dynamicToolPrefixes(
        for selectedGroups: Set<TerminalToolGroup>
    ) -> Set<String> {
        var prefixes = Set<String>()
        if selectedGroups.contains(.xcode) {
            prefixes.insert("xcode.")
        }
        if selectedGroups.contains(.figma) {
            prefixes.insert("figma.")
        }
        return prefixes
    }
}
