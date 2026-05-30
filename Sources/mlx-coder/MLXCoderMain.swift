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

        let didRequestSetup = MLXCoderSetupRunner.shouldRunSetup(arguments: arguments)
        let didRequestAgentSetup = MLXCoderAgentProfileSetupRunner.shouldRunSetup(arguments: arguments)
        if !didRequestSetup,
           !didRequestAgentSetup,
           MLXCoderSetupInspector.status().requiresSetup {
            arguments.append(MLXCoderSetupRunner.option)
        }

        if MLXCoderSetupRunner.shouldRunSetup(arguments: arguments)
            || MLXCoderAgentProfileSetupRunner.shouldRunSetup(arguments: arguments) {
            do {
                var didRunSetup = false
                if MLXCoderSetupRunner.shouldRunSetup(arguments: arguments) {
                    didRunSetup = true
                    try await MLXCoderSetupRunner.run(arguments: arguments)
                    arguments = MLXCoderSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
                }
                if MLXCoderAgentProfileSetupRunner.shouldRunSetup(arguments: arguments) {
                    didRunSetup = true
                    try MLXCoderAgentProfileSetupRunner.run(arguments: arguments)
                    arguments = MLXCoderAgentProfileSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
                }
                if didRunSetup, arguments.dropFirst().isEmpty {
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
                with: "mlx-coder [--setup] [--setup-agents] [--acp]"
            )
            .replacingOccurrences(
                of: "  --app                  App-hosted mode. Suppresses runtime chatter and requires explicit tool enablement.",
                with: """
                  --app                  App-hosted mode. Suppresses runtime chatter and requires explicit tool enablement.
                  --setup                Create standalone support files and configure providers/models, then exit.
                  --setup-agents         Create or update agent profiles in ~/.mlx-coder/agents.json, then exit.
                """
            )
    }
}
