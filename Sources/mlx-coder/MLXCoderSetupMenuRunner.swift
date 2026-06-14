import Foundation
import MLXCoderCore
import MLXCoderSetup
import MLXServerSetup

enum MLXCoderSetupMenuRunner {
    static let option = "--setup"
    private static let interactiveLineReader = TerminalInteractiveLineReader()

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    static func movedSetupOption(
        in arguments: [String],
        mlxMode: Bool
    ) -> String? {
        let movedOptions = mlxMode
            ? ["--setup", "--setup-models", "--reset", "--reset-disk-cache"]
            : ["--setup-agents", "--reset"]
        return arguments.dropFirst().first { movedOptions.contains($0) }
    }

    @MainActor
    static func run() async throws {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw MLXCoderSetupMenuError.nonInteractiveTerminal
        }

        AgentOutput.standardError.writeString(
            """
            mlx-coder setup
            Choose what you want to configure or reset.

            """
        )

        var didRunAction = false
        while true {
            let action = try promptAction()
            guard action != .finish else {
                break
            }

            try await run(action)
            didRunAction = true

            guard try promptYesNo("Run another setup action?", defaultValue: false) else {
                break
            }
        }

        if didRunAction {
            AgentOutput.standardError.writeString("\nSetup menu completed.\n\n")
        } else {
            AgentOutput.standardError.writeString("\nSetup unchanged.\n\n")
        }
    }

    @MainActor
    private static func run(_ action: SetupMenuAction) async throws {
        AgentOutput.standardError.writeString("\n")
        switch action {
        case .standaloneSetup:
            try await MLXCoderSetupRunner.run(arguments: [])
        case .agentProfiles:
            try MLXCoderAgentProfileSetupRunner.configureInteractively()
        case .localMLXRuntimeSetup:
            try MLXServerSetupRunner.run(arguments: [])
        case .localMLXModelsSetup:
            try await MLXServerModelSetupRunner.run(
                arguments: [],
                configureRetentionPolicy: true
            )
        case .standaloneReset:
            try MLXCoderResetConfigurationCommand.run()
        case .localMLXReset:
            try MLXCoderMLXResetConfigurationCommand.run()
        case .localMLXDiskCacheReset:
            try MLXCoderMLXResetDiskCacheCommand.run()
        case .finish:
            break
        }
        AgentOutput.standardError.writeString("\n")
    }

    private static func promptAction() throws -> SetupMenuAction {
        let options = SetupMenuAction.allCases
        let defaultAction: SetupMenuAction = .standaloneSetup
        let defaultIndex = options.firstIndex(of: defaultAction) ?? 0

        while true {
            AgentOutput.standardError.writeString("Setup menu:\n")
            for (index, action) in options.enumerated() {
                let marker = index == defaultIndex ? " *" : ""
                AgentOutput.standardError.writeString(
                    "  \(index + 1). \(action.title) - \(action.detail)\(marker)\n"
                )
            }

            let value = try promptString(
                "Action",
                defaultValue: String(defaultIndex + 1),
                allowEmpty: false
            )
            if let index = Int(value),
               options.indices.contains(index - 1) {
                return options[index - 1]
            }

            let normalizedValue = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if let action = options.first(where: { $0.matches(normalizedValue) }) {
                return action
            }
            throw MLXCoderSetupMenuError.invalidChoice(value)
        }
    }

    private static func promptString(
        _ label: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        guard let rawValue = interactiveLineReader.readLine(prompt: "\(label)\(suffix): ") else {
            throw MLXCoderSetupMenuError.cancelled
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, let defaultValue {
            return defaultValue
        }
        if value.isEmpty, !allowEmpty {
            throw MLXCoderSetupMenuError.emptyRequiredValue(label)
        }
        return value
    }

    private static func promptYesNo(
        _ label: String,
        defaultValue: Bool
    ) throws -> Bool {
        let suffix = defaultValue ? " [Y/n]" : " [y/N]"
        let value = try promptString(label + suffix, defaultValue: nil, allowEmpty: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.isEmpty {
            return defaultValue
        }
        switch value {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            throw MLXCoderSetupMenuError.invalidChoice(value)
        }
    }
}

private enum SetupMenuAction: CaseIterable, Equatable {
    case standaloneSetup
    case agentProfiles
    case localMLXRuntimeSetup
    case localMLXModelsSetup
    case standaloneReset
    case localMLXReset
    case localMLXDiskCacheReset
    case finish

    var title: String {
        switch self {
        case .standaloneSetup:
            return "mlx-coder setup"
        case .agentProfiles:
            return "Agent profiles"
        case .localMLXRuntimeSetup:
            return "Local MLX runtime setup"
        case .localMLXModelsSetup:
            return "Local MLX models setup"
        case .standaloneReset:
            return "Reset mlx-coder configuration"
        case .localMLXReset:
            return "Reset local MLX configuration"
        case .localMLXDiskCacheReset:
            return "Reset local MLX disk cache"
        case .finish:
            return "Exit"
        }
    }

    var detail: String {
        switch self {
        case .standaloneSetup:
            return "providers, models, integrations"
        case .agentProfiles:
            return "previously mlx-coder --setup-agents"
        case .localMLXRuntimeSetup:
            return "previously mlx-coder --mlx --setup"
        case .localMLXModelsSetup:
            return "previously mlx-coder --mlx --setup-models"
        case .standaloneReset:
            return "previously mlx-coder --reset"
        case .localMLXReset:
            return "previously mlx-coder --mlx --reset"
        case .localMLXDiskCacheReset:
            return "previously mlx-coder --mlx --reset-disk-cache"
        case .finish:
            return "leave setup"
        }
    }

    func matches(_ value: String) -> Bool {
        aliases.contains(value)
    }

    private var aliases: Set<String> {
        switch self {
        case .standaloneSetup:
            return ["setup", "mlx-coder setup", "providers", "models", "integrations"]
        case .agentProfiles:
            return ["agents", "agent", "profiles", "agent profiles", "setup-agents", "mlx-coder --setup-agents"]
        case .localMLXRuntimeSetup:
            return ["mlx", "mlx setup", "local mlx", "runtime", "mlx-coder --mlx --setup"]
        case .localMLXModelsSetup:
            return ["mlx models", "models setup", "setup-models", "mlx-coder --mlx --setup-models"]
        case .standaloneReset:
            return ["reset", "mlx-coder reset", "mlx-coder --reset"]
        case .localMLXReset:
            return ["mlx reset", "local mlx reset", "mlx-coder --mlx --reset"]
        case .localMLXDiskCacheReset:
            return ["disk cache", "reset disk cache", "reset-disk-cache", "mlx-coder --mlx --reset-disk-cache"]
        case .finish:
            return ["finish", "done", "exit", "quit", "end", "stop"]
        }
    }
}

enum MLXCoderSetupMenuError: LocalizedError {
    case nonInteractiveTerminal
    case cancelled
    case emptyRequiredValue(String)
    case invalidChoice(String)
    case setupActionMovedToSetup(String)

    var errorDescription: String? {
        switch self {
        case .nonInteractiveTerminal:
            return "Setup requires an interactive terminal."
        case .cancelled:
            return "Setup cancelled."
        case .emptyRequiredValue(let label):
            return "\(label) is required."
        case .invalidChoice(let value):
            return "Invalid setup choice: \(value)"
        case .setupActionMovedToSetup(let option):
            return "\(option) is now available from mlx-coder --setup."
        }
    }
}
