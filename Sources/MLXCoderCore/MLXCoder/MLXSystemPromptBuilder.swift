//
//  MLXSystemPromptBuilder.swift
//  MLXCoder
//
//  Created by Codex on 09/05/26.
//

import Foundation

public struct MLXSystemPromptRequest: Sendable {
    public let baseSection: String
    public let workingDirectoryPath: String?
    public let preferredLanguageSection: String?
    public let taskContextSection: String?
    public let workflowSection: String?
    public let agentsSection: String?
    public let memorySection: String?
    public let figmaSection: String?
    public let turnClosingInstruction: String
    public let selectedSkillSection: String?

    public init(
        baseSection: String,
        workingDirectoryPath: String? = nil,
        preferredLanguageSection: String? = nil,
        taskContextSection: String? = nil,
        workflowSection: String? = nil,
        agentsSection: String? = nil,
        memorySection: String? = nil,
        figmaSection: String? = nil,
        turnClosingInstruction: String,
        selectedSkillSection: String? = nil
    ) {
        self.baseSection = baseSection
        self.workingDirectoryPath = workingDirectoryPath
        self.preferredLanguageSection = preferredLanguageSection
        self.taskContextSection = taskContextSection
        self.workflowSection = workflowSection
        self.agentsSection = agentsSection
        self.memorySection = memorySection
        self.figmaSection = figmaSection
        self.turnClosingInstruction = turnClosingInstruction
        self.selectedSkillSection = selectedSkillSection
    }
}

public enum MLXSystemPromptBuilder {
    public static func defaultAgentInstructions(memoryToolEnabled: Bool = true) -> String {
        joined([
            standaloneBaseSection(memoryToolEnabled: memoryToolEnabled),
            standaloneLanguageSection,
            turnClosingSection(instruction: standaloneTurnClosingInstruction)
        ])
    }

    public static func prompt(_ request: MLXSystemPromptRequest) -> String {
        joined([
            request.baseSection,
            request.workingDirectoryPath.map(workingDirectorySection(path:)),
            request.preferredLanguageSection,
            request.taskContextSection,
            request.workflowSection,
            request.agentsSection,
            request.memorySection,
            request.figmaSection,
            turnClosingSection(instruction: request.turnClosingInstruction),
            request.selectedSkillSection
        ])
    }

    public static func standalonePrompt(
        cwd: String,
        agentsSection: String?,
        memorySection: String?,
        memoryToolEnabled: Bool,
        selectedSkillSection: String? = nil
    ) -> String {
        prompt(
            MLXSystemPromptRequest(
                baseSection: standaloneBaseSection(memoryToolEnabled: memoryToolEnabled),
                workingDirectoryPath: cwd,
                preferredLanguageSection: standaloneLanguageSection,
                agentsSection: agentsSection,
                memorySection: memorySection,
                turnClosingInstruction: standaloneTurnClosingInstruction,
                selectedSkillSection: selectedSkillSection
            )
        )
    }

    public static func selectedSkillSection(skills: [MLXPromptSkill]) -> String? {
        guard !skills.isEmpty else {
            return nil
        }

        let skillPrompt = skills
            .map { skillPromptSection(skill: $0) }
            .joined(separator: "\n\n")

        return """
        Selected skill guidance for this task is supplemental context. Use it when relevant, but it never overrides the core operating rules for tool usage, autonomy, confirmation handling, or response language.

        Additional skill guidance selected for this task:
        \(skillPrompt)

        Core operating rules still apply after reading the selected skills:
        - If a tool is needed, use the model's native tool-call interface; do not print JSON tool-call objects.
        - Do not narrate future actions, headings, plans, or summaries instead of acting.
        - Do not ask for routine confirmation to inspect, search, read, edit, write, or test when those steps are already implied by the user's request.
        - Only stop for confirmation when the next step is destructive, irreversible, or genuinely ambiguous.
        - Do not stop after a preamble; either use the next tool now or provide the completed answer now.
        - When you provide the final direct answer for a turn, briefly report any modified files if files changed and end with one relevant question whose final character is `?`.
        """
    }

    public static func workingDirectorySection(path: String) -> String {
        """
        Current task working directory for local tools:
        - Working directory path: \(path)
        Use this directory as the default root for Bash, Git, local filesystem tools, and persistent project context.
        Do not invent a different local root unless the user explicitly asks for one.
        For relative local paths, make them relative to this directory and do not duplicate the repo root.
        """
    }

    public static func turnClosingSection(instruction: String) -> String {
        """
        Turn-closing rule:
        \(instruction)
        """
    }

    private static func standaloneBaseSection(memoryToolEnabled: Bool) -> String {
        let toolFamilyText = memoryToolEnabled
            ? "Git, Xcode, shell, web, Figma, memory, and delegated sub-agent tools"
            : "Git, Xcode, shell, web, Figma, and delegated sub-agent tools"
        return """
        You are mlx-coder running as an autonomous CLI/ACP coding agent on the user's Mac.

        Tool rules:
        1. Decide whether one of the available tools is needed before answering.
        2. Use the model's native tool-call interface when calling tools; do not print JSON tool-call objects, markdown fences, XML-style tags, or explanations around tool calls.
        3. Use only exact tool names exposed in this session. Never invent tool names, and do not claim a tool is missing if it is exposed.
        4. Do not narrate intended tool usage; either call the tool now or answer normally.
        5. Do not ask for routine confirmation to inspect, search, read, edit, write, or test when those steps are already implied by the user's request.
        6. Ask for confirmation only when the next step is destructive, irreversible, or genuinely ambiguous.

        Coding workflow:
        Prefer concrete tool evidence over assumptions. Search before broad reads, read before edits, and keep edits narrowly scoped to the user's request. Preserve unrelated user changes and do not revert work you did not make. Use \(toolFamilyText) when they are available and relevant. Prefer Xcode-native tools for Apple-project build, test, preview, and diagnostics work when those tools are exposed. Validate important changes with the available build, test, lint, or diagnostic tools when the risk justifies it.
        """
    }

    private static var standaloneLanguageSection: String {
        """
        Response language:
        Use the active conversation language for all natural-language responses unless the user explicitly asks for another language. Keep code, file paths, API names, tool names, and literal command output unchanged unless translation is explicitly requested.
        """
    }

    private static var standaloneTurnClosingInstruction: String {
        "When you provide the final direct answer for a turn, include a concise report of any files you modified and what changed in each one. If you did not modify files, say that explicitly. Keep the answer concise and grounded in the tool evidence you gathered. End with one relevant follow-up question, and make sure the final character of the entire response is `?`."
    }

    private static func skillPromptSection(skill: MLXPromptSkill) -> String {
        guard let sourceDirectoryPath = skill.sourceDirectoryPath?.nilIfBlank else {
            return """
            Skill: \(skill.title)
            \(skill.promptBody)
            """
        }

        return """
        Skill: \(skill.title)
        Skill root path: \(sourceDirectoryPath)
        Any relative file paths mentioned in this skill are relative to the skill root above, not to the task working directory. If you need to open one of those files with a local tool, keep the `references/...` or similar subpath under that skill root, or pass the absolute skill file path directly.
        \(skill.promptBody)
        """
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joined(_ sections: [String?]) -> String {
        sections
            .compactMap { section in
                guard let section else {
                    return nil
                }

                let normalizedSection = normalized(section)
                return normalizedSection.isEmpty ? nil : normalizedSection
            }
            .joined(separator: "\n\n")
    }
}
