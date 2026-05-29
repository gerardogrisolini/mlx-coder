//
//  Generated split from MLXCoder.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public enum TerminalChatError: LocalizedError {
    case noInputReceived
    case noConfiguredModels
    case modelSelectionRequired
    case interactivePromptUnavailable

    public var errorDescription: String? {
        switch self {
        case .noInputReceived:
            return "No input received on stdin. Run mlx-coder from an interactive terminal, pipe a prompt, or pass --acp for ACP clients."
        case .noConfiguredModels:
            return "No models are configured for mlx-coder. Configure local or remote models in mlx-coder first."
        case .modelSelectionRequired:
            return "No model selected. Run mlx-coder in an interactive terminal and choose one with /models."
        case .interactivePromptUnavailable:
            return "Interactive prompt unavailable: no foreground controlling terminal is available for raw input."
        }
    }
}

public enum TerminalToolGroup: String, CaseIterable, Hashable, Sendable {
    case bash
    case git
    case memory
    case web
    case orchestration
    case xcode
    case figma

    public var displayTitle: String {
        switch self {
        case .bash:
            return "Bash"
        case .git:
            return "Git"
        case .memory:
            return "Memory"
        case .web:
            return "Web"
        case .orchestration:
            return "Sub-Agents"
        case .xcode:
            return "Xcode"
        case .figma:
            return "Figma"
        }
    }

    public var description: String {
        switch self {
        case .bash:
            return "local files, shell, and search"
        case .git:
            return "git status, history, branches, staging, and commits"
        case .memory:
            return "memory notes and session todo list"
        case .web:
            return "web tools when provided by the runtime"
        case .orchestration:
            return "delegated sub-agents and orchestration tasks"
        case .xcode:
            return "Xcode MCP tools"
        case .figma:
            return "Figma MCP tools"
        }
    }

    public static func group(named rawName: String) -> TerminalToolGroup? {
        let normalizedName = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedName {
        case "bash", "shell", "local", "files", "file", "search":
            return .bash
        case "git":
            return .git
        case "memory", "mem", "remember", "todo", "todos":
            return .memory
        case "web", "browser":
            return .web
        case "orchestration", "agents", "agent", "subagents", "sub-agents", "tasks", "task":
            return .orchestration
        case "xcode":
            return .xcode
        case "figma":
            return .figma
        default:
            return nil
        }
    }

    public func allows(toolName: String) -> Bool {
        switch self {
        case .bash:
            return toolName.hasPrefix("local.")
                || toolName.hasPrefix("search.")
                || toolName.hasPrefix("text.")
        case .git:
            return toolName.hasPrefix("git.")
        case .memory:
            return toolName.hasPrefix("memory.")
                || toolName.hasPrefix("todo.")
        case .web:
            return toolName.hasPrefix("web.")
        case .orchestration:
            return toolName.hasPrefix("agent.")
                || toolName.hasPrefix("task.")
        case .xcode:
            return DirectMCPToolRuntime.isXcodeToolName(toolName)
        case .figma:
            return toolName.hasPrefix("figma.")
        }
    }
}

public enum TerminalToolSelectionError: LocalizedError {
    case unknownToken(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownToken(token):
            return "Unknown tool group '\(token)'."
        }
    }
}

public enum TerminalSkillSelectionError: LocalizedError {
    case unknownToken(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownToken(token):
            return "Unknown skill '\(token)'."
        }
    }
}
