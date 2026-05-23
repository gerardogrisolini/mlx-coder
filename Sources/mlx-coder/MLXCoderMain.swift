import Foundation
import MLXCoderCore

@main
struct MLXCoderMain {
    static func main() async {
        var arguments = MLXCoderCommandLineArgumentSanitizer.sanitized(CommandLine.arguments)
        if arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            AgentOutput.standardOutput.writeString(MLXCoderStandaloneHelp.text)
            return
        }

        if MLXCoderSetupRunner.shouldRunSetup(arguments: arguments) {
            do {
                try MLXCoderSetupRunner.run(arguments: arguments)
                arguments = MLXCoderSetupRunner.argumentsAfterRemovingSetup(arguments: arguments)
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
                with: "mlx-coder [--setup] [--acp]"
            )
            .replacingOccurrences(
                of: "  --app                  App-hosted mode. Suppresses runtime chatter and requires explicit tool enablement.",
                with: """
                  --app                  App-hosted mode. Suppresses runtime chatter and requires explicit tool enablement.
                  --setup                Create standalone support files, configure providers/models, then start mlx-coder.
                """
            )
    }
}
