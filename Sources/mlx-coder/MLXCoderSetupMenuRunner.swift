import Foundation
import MLXCoderSetup
#if MLX_CODER_LOCAL_MLX
import MLXServerSetup
#endif

enum MLXCoderSetupMenuRunner {
    static let option = "--setup"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    static func movedSetupOption(
        in arguments: [String],
        mlxMode: Bool
    ) -> String? {
        let movedOptions: [String]
        if mlxMode {
            #if MLX_CODER_LOCAL_MLX
            movedOptions = ["--setup", "--setup-models", "--reset", "--reset-disk-cache"]
            #else
            movedOptions = []
            #endif
        } else {
            movedOptions = ["--setup-agents", "--reset"]
        }
        return arguments.dropFirst().first { movedOptions.contains($0) }
    }

    static func additionalSectionGroups() -> [MLXCoderSetupAdditionalSectionGroup] {
        var groups: [MLXCoderSetupAdditionalSectionGroup] = []

        #if MLX_CODER_LOCAL_MLX
        groups.append(
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
            )
        )
        #endif

        var resetSections: [MLXCoderSetupAdditionalSection] = [
            MLXCoderSetupAdditionalSection(
                title: "Reset mlx-coder configuration",
                detail: "remove standalone support files",
                aliases: ["reset mlx-coder", "reset configuration"]
            ) {
                try MLXCoderResetConfigurationCommand.run()
                return .removedStandaloneConfiguration
            }
        ]

        #if MLX_CODER_LOCAL_MLX
        resetSections += [
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
        #endif

        groups.append(
            MLXCoderSetupAdditionalSectionGroup(
                title: "Reset",
                detail: "configuration and cache",
                aliases: ["reset", "resets"],
                placement: .afterVoice,
                prefersBackDefault: true,
                sections: resetSections
            )
        )

        return groups
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
