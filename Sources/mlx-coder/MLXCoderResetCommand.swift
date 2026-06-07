import Foundation
import MLXCoderCore

enum MLXCoderResetConfigurationCommand {
    static let option = "--reset"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    static func argumentsAfterRemovingOption(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    static func run(fileManager: FileManager = .default) throws {
        let fileURLs = uniqueURLs([
            MLXAgentsContextService(fileManager: fileManager).globalAgentsFileURL(),
            MLXMemoryService(fileManager: fileManager).globalMemoryFileURL(),
            AgentProfileStore.agentsManifestURL(fileManager: fileManager),
            AgentSettingsManifestStore.settingsURL(fileManager: fileManager),
            AgentPermissionsManifestStore.permissionsURL(fileManager: fileManager)
        ])

        var removed: [URL] = []
        var missing: [URL] = []
        for url in fileURLs {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removed.append(url)
            } else {
                missing.append(url)
            }
        }

        AgentOutput.standardError.writeString("mlx-coder reset completed.\n")
        printURLs("Removed", removed)
        if removed.isEmpty {
            printURLs("Missing", missing)
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls.map(\.standardizedFileURL) {
            guard seen.insert(url.path).inserted else {
                continue
            }
            result.append(url)
        }
        return result
    }

    private static func printURLs(_ title: String, _ urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        AgentOutput.standardError.writeString("\(title):\n")
        for url in urls {
            AgentOutput.standardError.writeString("- \(url.path)\n")
        }
    }
}
