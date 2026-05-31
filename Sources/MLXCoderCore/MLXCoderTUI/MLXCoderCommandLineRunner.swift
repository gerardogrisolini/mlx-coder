//
//  MLXCoderCommandLineRunner.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public enum MLXCoderCommandLineRunner {
    public static func main() async {
        await main(arguments: CommandLine.arguments)
    }

    public static func main(arguments rawArguments: [String]) async {
        do {
            SwiftPMResourceBundleDirectory.configure()

            let configuration = try AgentConfiguration(
                arguments: MLXCoderCommandLineArgumentSanitizer.sanitized(rawArguments)
            )
            if configuration.printHelp {
                AgentOutput.standardOutput.writeString(AgentConfiguration.helpText)
                return
            }
            if configuration.printVersion {
                AgentOutput.standardOutput.writeString("mlx-coder \(agentVersion)\n")
                return
            }

            let interactiveInputAvailable = TerminalRawInput.supportsInteractiveInput()
            let resolvedRunMode = configuration.resolvedRunMode(
                stdinIsTerminal: interactiveInputAvailable
            )

            switch resolvedRunMode {
            case .chat:
                if interactiveInputAvailable {
                    AgentOutput.clearTerminalScreenIfNeeded()
                }
                AgentOutput.silenceInheritedProcessOutput(
                    keepStandardError: configuration.verboseLogging
                )
                let terminal = TerminalChat(
                    configuration: configuration,
                    stdinIsTerminal: interactiveInputAvailable
                )
                try await terminal.run()
                return
            case .acp:
                if !configuration.verboseLogging {
                    AgentOutput.silenceInheritedProcessError()
                }
                break
            }

            let writer = ACPWriter()
            let bridge = MLXCoderACPBridge(
                configuration: configuration,
                writer: writer
            )
            let reader = StdioLineReader()
            let lines = AsyncStream<String> { continuation in
                let task = Task.detached {
                    while let line = reader.readLine() {
                        continuation.yield(line)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }

            await withTaskGroup(of: Void.self) { group in
                for await line in lines {
                    let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmedLine.isEmpty else {
                        continue
                    }
                    group.addTask {
                        await bridge.handleLine(trimmedLine)
                    }
                }
            }

            await bridge.shutdown()
        } catch {
            AgentOutput.standardError.writeString("mlx-coder: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
    }

    public static func shouldRunAsCommandLine(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard let executablePath = arguments.first else {
            return false
        }
        let sanitizedArguments = MLXCoderCommandLineArgumentSanitizer.sanitized(arguments)

        let executableURL = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
        guard executableURL.lastPathComponent == "mlx-coder" else {
            return false
        }

        if sanitizedArguments.dropFirst().contains(where: isCommandLineOption(_:)) {
            return true
        }

        if !executableURL.path.contains(".app/Contents/MacOS/") {
            return true
        }

        if sanitizedArguments.count == 1,
           MLXCoderCommandLineArgumentSanitizer.containsCocoaLaunchArguments(arguments) {
            return false
        }

        return isatty(STDIN_FILENO) == 1
    }

    private static func isCommandLineOption(_ argument: String) -> Bool {
        argument == "-h"
            || argument == "--help"
            || argument == "--version"
            || argument == "--model"
            || argument == "--agent"
            || argument == "--bearer-token"
            || argument == "--acp"
            || argument == "--app"
            || argument == "--cwd"
            || argument == "--skills"
            || argument == "--max-tool-rounds"
            || argument == "--max-output-tokens"
            || argument == "--verbose"
    }
}

public enum MLXCoderCommandLineArgumentSanitizer {
    public static func sanitized(_ arguments: [String]) -> [String] {
        guard let executable = arguments.first else {
            return []
        }

        var result = [executable]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if isCocoaLaunchArgument(argument) {
                index += 1
                if index < arguments.count, !arguments[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }

            result.append(argument)
            index += 1
        }

        return result
    }

    public static func containsCocoaLaunchArguments(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(where: isCocoaLaunchArgument(_:))
    }

    private static func isCocoaLaunchArgument(_ argument: String) -> Bool {
        argument == "-NSDocumentRevisionsDebugMode"
            || argument == "-ApplePersistenceIgnoreState"
            || argument == "-NSQuitAlwaysKeepsWindows"
            || argument.hasPrefix("-NS")
            || argument.hasPrefix("-Apple")
    }
}
