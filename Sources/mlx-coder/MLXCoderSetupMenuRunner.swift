import Foundation
import MLXCoderSetup
import MLXServerSetup

enum MLXCoderSetupMenuRunner {
    static let option = "--setup"

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

    static func additionalSectionGroups() -> [MLXCoderSetupAdditionalSectionGroup] {
        [
            MLXCoderSetupAdditionalSectionGroup(
                title: "Local MLX runtime",
                detail: "runtime and models",
                aliases: ["mlx", "mlx setup", "local mlx", "runtime"],
                placement: .afterAgents,
                sections: [
                    MLXCoderSetupAdditionalSection(
                        title: "Local MLX runtime",
                        detail: "settings and cache policy",
                        aliases: ["mlx", "mlx setup", "local mlx", "runtime"]
                    ) {
                        try MLXServerSetupRunner.run(arguments: [])
                        return .unchanged
                    },
                    MLXCoderSetupAdditionalSection(
                        title: "Local MLX models",
                        detail: "catalog and downloads",
                        aliases: ["mlx models", "models setup"]
                    ) {
                        try await MLXServerModelSetupRunner.run(
                            arguments: [],
                            configureRetentionPolicy: true
                        )
                        return .unchanged
                    }
                ]
            ),
            MLXCoderSetupAdditionalSectionGroup(
                title: "Reset",
                detail: "configuration and cache",
                aliases: ["reset", "resets"],
                placement: .afterVoice,
                prefersBackDefault: true,
                sections: [
                    MLXCoderSetupAdditionalSection(
                        title: "Reset mlx-coder configuration",
                        detail: "remove standalone support files",
                        aliases: ["reset mlx-coder", "reset configuration"]
                    ) {
                        try MLXCoderResetConfigurationCommand.run()
                        return .removedStandaloneConfiguration
                    },
                    MLXCoderSetupAdditionalSection(
                        title: "Reset local MLX configuration",
                        detail: "remove local runtime settings",
                        aliases: ["mlx reset", "local mlx reset"]
                    ) {
                        try MLXCoderMLXResetConfigurationCommand.run()
                        return .unchanged
                    },
                    MLXCoderSetupAdditionalSection(
                        title: "Reset local MLX disk cache",
                        detail: "clear persisted local KV cache",
                        aliases: ["disk cache", "reset disk cache", "kv cache", "cache"]
                    ) {
                        try MLXCoderMLXResetDiskCacheCommand.run()
                        return .unchanged
                    }
                ]
            )
        ]
    }
}

enum MLXCoderSetupMenuError: LocalizedError {
    case setupActionMovedToSetup(String)

    var errorDescription: String? {
        switch self {
        case .setupActionMovedToSetup(let option):
            return "\(option) is now available from mlx-coder --setup."
        }
    }
}
