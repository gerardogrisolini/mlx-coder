//
//  MLXAppStorageDirectory.swift
//  MLXShared
//
//  Created by Codex on 13/05/26.
//

import Foundation

public enum MLXAppStorageDirectory {
    public static let supportDirectoryEnvironmentKey = "MLX_CODER_SUPPORT_DIRECTORY"
    private static let supportDirectoryName = ".mlx-coder"
    private static let supportDirectoryOverride = SupportDirectoryOverride()

    public static func configureSupportDirectoryURL(_ url: URL?) {
        supportDirectoryOverride.set(url?.standardizedFileURL)
    }

    public static func appSupportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        if let configuredDirectoryURL = configuredSupportDirectoryURL() {
            return configuredDirectoryURL
        }
        return defaultSupportDirectoryURL(fileManager: fileManager)
    }

    public static func defaultSupportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        MLXUserHomeDirectory.current(fileManager: fileManager)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func configuredSupportDirectoryURL() -> URL? {
        if let url = supportDirectoryOverride.url() {
            return url
        }
        guard let rawValue = normalizedPath(ProcessInfo.processInfo.environment[supportDirectoryEnvironmentKey]) else {
            return nil
        }
        return URL(fileURLWithPath: rawValue, isDirectory: true)
            .standardizedFileURL
    }

    private static func normalizedPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private final class SupportDirectoryOverride: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URL?

    func set(_ url: URL?) {
        lock.lock()
        value = url
        lock.unlock()
    }

    func url() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
