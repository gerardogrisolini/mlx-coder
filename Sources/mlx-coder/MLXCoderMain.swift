import Foundation
import MLXCoderCore
import MLXCoderSetup

@main
struct MLXCoderMain {
    static func main() async {
        var arguments = MLXCoderCommandLineArgumentSanitizer.sanitized(CommandLine.arguments)
        if arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            AgentOutput.standardOutput.writeString(MLXCoderStandaloneHelp.text)
            return
        }

        if MLXCoderResetConfigurationCommand.shouldRun(arguments: arguments) {
            do {
                try MLXCoderResetConfigurationCommand.run()
                arguments = MLXCoderResetConfigurationCommand.argumentsAfterRemovingOption(
                    arguments: arguments
                )
                if arguments.dropFirst().isEmpty {
                    return
                }
            } catch {
                AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
        }

                let didRequestSetup = MLXCoderSetupRunner.shouldRunSetup(arguments: arguments)
        if !didRequestSetup,
           MLXCoderSetupInspector.status().requiresSetup {
            arguments.append(MLXCoderSetupRunner.option)
        }

        if MLXCoderSetupRunner.shouldRunSetup(arguments: arguments) {
            do {
                try await MLXCoderSetupRunner.run(arguments: arguments)
                arguments = MLXCoderSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
                if arguments.dropFirst().isEmpty {
                    return
                }
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
        AgentConfiguration.helpText
            .replacingOccurrences(
                of: "mlx-coder [--acp]",
                                with: "mlx-coder [--setup] [--reset] [--acp]"
            )
            .replacingOccurrences(
                of: "  --app                  App-hosted mode. Suppresses runtime chatter and requires explicit tool enablement.",
                with: """
                  --app                  App-hosted mode. Suppresses runtime chatter and requires explicit tool enablement.
                                    --setup                Create standalone support files and configure providers, models, and agents, then exit.
                  --reset                Delete managed files in ~/.mlx-coder, then exit.
                """
            )
    }
}
