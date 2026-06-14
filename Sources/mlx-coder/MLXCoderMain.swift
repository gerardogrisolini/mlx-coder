import Foundation
import MLXCoderCore
import MLXCoderSetup

@main
struct MLXCoderMain {
    static func main() async {
        let arguments = MLXCoderCommandLineArgumentSanitizer.sanitized(CommandLine.arguments)
        if arguments.dropFirst().contains("--mlx"),
           let option = MLXCoderSetupMenuRunner.movedSetupOption(
               in: arguments,
               mlxMode: true
           ) {
            AgentOutput.standardError.writeString(
                "mlx-coder: \(MLXCoderSetupMenuError.setupActionMovedToSetup(option).localizedDescription)\n"
            )
            Foundation.exit(1)
        }

        let didRequestSetup = MLXCoderSetupMenuRunner.shouldRun(arguments: arguments)
        if didRequestSetup {
            do {
                try await MLXCoderSetupRunner.run(
                    arguments: [],
                    additionalSectionGroups: MLXCoderSetupMenuRunner.additionalSectionGroups()
                )
            } catch {
                AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            return
        }

        if arguments.dropFirst().contains("--mlx") {
            do {
                try await MLXCoderMLXCommand.run(arguments: arguments)
            } catch {
                AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            return
        }

        if arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            AgentOutput.standardOutput.writeString(MLXCoderStandaloneHelp.text)
            return
        }

        if let option = MLXCoderSetupMenuRunner.movedSetupOption(
            in: arguments,
            mlxMode: false
        ) {
            AgentOutput.standardError.writeString(
                "mlx-coder: \(MLXCoderSetupMenuError.setupActionMovedToSetup(option).localizedDescription)\n"
            )
            Foundation.exit(1)
        }

        if MLXCoderSetupInspector.status().requiresSetup {
            do {
                try await MLXCoderSetupRunner.run(
                    arguments: [],
                    additionalSectionGroups: MLXCoderSetupMenuRunner.additionalSectionGroups()
                )
            } catch {
                AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
        }

        await MLXCoderCommandLineRunner.main(arguments: arguments)
    }
}

private enum MLXCoderStandaloneHelp {
    static var text: String {
        #if MLX_CODER_LOCAL_MLX
        AgentConfiguration.helpText
            .replacingOccurrences(
                of: "mlx-coder [--acp]",
                with: "mlx-coder [--setup] [--mlx] [--acp]"
            )
            .replacingOccurrences(
                of: "  --acp                  ACP JSON-RPC over stdio for compatible clients.",
                with: """
                  --acp                  ACP JSON-RPC over stdio for compatible clients.
                  --setup                Open setup for providers, models, agents, local MLX, and resets.
                  --mlx                  Use the embedded local MLX runtime. Run mlx-coder --setup for setup and reset options.
                """
            )
        #else
        AgentConfiguration.helpText
            .replacingOccurrences(
                of: "mlx-coder [--acp]",
                with: "mlx-coder [--setup] [--acp]"
            )
            .replacingOccurrences(
                of: "  --acp                  ACP JSON-RPC over stdio for compatible clients.",
                with: """
                  --acp                  ACP JSON-RPC over stdio for compatible clients.
                  --setup                Open setup for providers, models, agents, and resets.
                """
            )
        #endif
    }
}
