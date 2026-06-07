//
//  TerminalChat+Commands.swift
//  mlx-coder
//

import Foundation

struct TerminalChatCommandDescriptor: Sendable, Equatable {
    var command: String
    var summary: String
    var help: String
    var requiresArgument: Bool = false
    var availability: TerminalChatCommandAvailability = .always
}

enum TerminalChatCommandAvailability: Sendable, Equatable {
    case always
    case builderAgent
    case telegramEnabled
    case voiceEnabled
    case voiceSynthesisEnabled
}

extension TerminalChat {
    func visibleCommandDescriptorsForCurrentAgent() -> [TerminalChatCommandDescriptor] {
        Self.visibleCommandDescriptors(
            builderAgentEnabled: AgentProfileStore.isBuilderAgent(selectedAgent),
            telegramEnabled: isTelegramConfigured(),
            voiceEnabled: isVoiceConfigured(),
            voiceSynthesisEnabled: isVoiceSynthesisConfigured()
        )
    }

    static func visibleCommandDescriptors(
        builderAgentEnabled: Bool,
        telegramEnabled: Bool,
        voiceEnabled: Bool,
        voiceSynthesisEnabled: Bool? = nil
    ) -> [TerminalChatCommandDescriptor] {
        allCommandDescriptors.filter { descriptor in
            switch descriptor.availability {
            case .always:
                return true
            case .builderAgent:
                return builderAgentEnabled
            case .telegramEnabled:
                return telegramEnabled
            case .voiceEnabled:
                return voiceEnabled
            case .voiceSynthesisEnabled:
                return voiceSynthesisEnabled ?? voiceEnabled
            }
        }
    }

    func visibleCommandNamesForCurrentAgent() -> [String] {
        visibleCommandDescriptorsForCurrentAgent().map(\.command)
    }

    func isTelegramConfigured() -> Bool {
        AgentSettingsManifestStore.load()?.telegram?.isEnabled == true
    }

    func isTelegramCommandVisible() -> Bool {
        isTelegramConfigured()
    }

    func isVoiceConfigured() -> Bool {
        AgentSettingsManifestStore.load()?.voice?.isConfigured == true
    }

    func isVoiceCommandVisible() -> Bool {
        isVoiceConfigured()
    }

    func isVoiceSynthesisConfigured() -> Bool {
        isVoiceConfigured() && AgentVoiceSynthesisService.isSupported
    }

    static func commandToken(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }
        return trimmed
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }

    static func unknownCommandMessage(for line: String) -> String {
        let command = commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "mlx-coder: unknown command '\(command)'.\n"
    }

    private static let allCommandDescriptors: [TerminalChatCommandDescriptor] = [
        TerminalChatCommandDescriptor(
            command: "/help",
            summary: "show command help",
            help: "/help shows this command list."
        ),
        TerminalChatCommandDescriptor(
            command: "/models",
            summary: "switch model",
            help: "/models shows configured models and lets you switch the current session model."
        ),
        TerminalChatCommandDescriptor(
            command: "/agents",
            summary: "switch agent",
            help: "/agents selects an agent profile and resets the session."
        ),
        TerminalChatCommandDescriptor(
            command: "/tools",
            summary: "select tool groups",
            help: "/tools selects which tool groups are available to the model."
        ),
        TerminalChatCommandDescriptor(
            command: "/feature",
            summary: "create/manage features",
            help: "/feature creates and manages generated Swift feature packages.",
            availability: .builderAgent
        ),
        TerminalChatCommandDescriptor(
            command: "/skills",
            summary: "select/install prompt skills",
            help: "/skills selects installed prompt skills or installs one from GitHub or a local folder."
        ),
        TerminalChatCommandDescriptor(
            command: "/sessions",
            summary: "save/load/delete sessions",
            help: "/sessions saves, restores, or deletes named session snapshots for this project."
        ),
        TerminalChatCommandDescriptor(
            command: "/attach",
            summary: "attach files",
            help: "/attach <file> [file ...] attaches image or video files to the next prompt.",
            requiresArgument: true
        ),
        TerminalChatCommandDescriptor(
            command: "/attachments",
            summary: "show pending attachments",
            help: "/attachments shows pending attachments."
        ),
        TerminalChatCommandDescriptor(
            command: "/detach",
            summary: "remove attachments",
            help: "/detach [all|number] removes pending attachments.",
            requiresArgument: true
        ),
        TerminalChatCommandDescriptor(
            command: "/retry",
            summary: "rerun failed prompt",
            help: "/retry reruns the most recent failed prompt."
        ),
        TerminalChatCommandDescriptor(
            command: "/changes",
            summary: "show last file changes",
            help: "/changes shows the most recent file change summary. Use /changes diff to include patches."
        ),
        TerminalChatCommandDescriptor(
            command: "/undo",
            summary: "revert last file changes",
            help: "/undo reverts the most recent tracked file changes."
        ),
        TerminalChatCommandDescriptor(
            command: "/subagents",
            summary: "show sub-agent status",
            help: "/subagents shows delegated sub-agent status. Use /subagents off to hide automatic updates."
        ),
        TerminalChatCommandDescriptor(
            command: "/telegram",
            summary: "turn Telegram on/off",
            help: "/telegram shows Telegram status. Use /telegram on or /telegram off for this TUI session.",
            availability: .telegramEnabled
        ),
        TerminalChatCommandDescriptor(
            command: "/voice",
            summary: "record a voice prompt",
            help: "/voice starts recording. Press Enter again to stop and send the transcript.",
            availability: .voiceEnabled
        ),
        TerminalChatCommandDescriptor(
            command: "/speak",
            summary: "play last response aloud",
            help: "/speak synthesizes and plays the last assistant response.",
            availability: .voiceSynthesisEnabled
        ),
        TerminalChatCommandDescriptor(
            command: "/clear",
            summary: "reset conversation",
            help: "/clear resets the conversation."
        ),
        TerminalChatCommandDescriptor(
            command: "/exit",
            summary: "close session",
            help: "/exit closes the session."
        )
    ]
}
