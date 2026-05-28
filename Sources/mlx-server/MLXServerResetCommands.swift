//
//  MLXServerResetCommands.swift
//  mlx-server
//

import Foundation
import MLXCoderCore
import MLXServerCore

enum MLXServerResetConfigurationCommand {
    static let option = "--reset"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    static func argumentsAfterRemovingOption(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    static func run(fileManager: FileManager = .default) throws {
        let fileURLs = uniqueURLs([
            MLXServerSettingsStore.settingsURL(fileManager: fileManager),
            MLXServerModelsManifestStore.modelsURL(fileManager: fileManager),
            MLXAgentsContextService(fileManager: fileManager).globalAgentsFileURL(),
            MLXMemoryService(fileManager: fileManager).globalMemoryFileURL(),
            AgentProfileStore.agentsManifestURL(fileManager: fileManager),
            AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
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

        FileHandle.standardError.writeString("Configuration reset completed.\n")
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
        FileHandle.standardError.writeString("\(title):\n")
        for url in urls {
            FileHandle.standardError.writeString("- \(url.path)\n")
        }
    }
}

enum MLXServerResetDiskCacheCommand {
    static let option = "--reset-disk-cache"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.contains(option)
    }

    static func argumentsAfterRemovingOption(arguments: [String]) -> [String] {
        arguments.filter { $0 != option }
    }

    static func run(fileManager: FileManager = .default) throws {
        let settings = MLXServerSettingsStore.loadOrDefault(fileManager: fileManager)
        let cacheDirectory = settings.diskKVCache.configuration.directory.standardizedFileURL

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cacheDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            FileHandle.standardError.writeString(
                "Disk KV cache not found: \(cacheDirectory.path)\n"
            )
            return
        }

        let children = try fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            try fileManager.removeItem(at: child)
        }

        FileHandle.standardError.writeString(
            "Disk KV cache cleared: \(cacheDirectory.path)\n"
        )
    }
}

private extension FileHandle {
    func writeString(_ string: String) {
        try? write(contentsOf: Data(string.utf8))
    }
}
