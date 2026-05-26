//
//  MLXAppStorageDirectory.swift
//  MLXShared
//
//  Created by Codex on 13/05/26.
//

import Foundation
#if os(macOS)
import Darwin
#endif

public enum MLXAppStorageDirectory {
    public static let appBundleIdentifier = "com.grisolini.mlx-coder"
    public static let supportDirectoryEnvironmentKey = "MLX_CODER_SUPPORT_DIRECTORY"
    private static let supportDirectoryName = "mlx-coder"
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
        if let executableDirectoryURL = executableDirectoryURL(fileManager: fileManager),
           !isAppBundleExecutableDirectory(executableDirectoryURL) {
            return executableDirectoryURL
        }

        #if os(Linux)
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".mlx-coder", isDirectory: true)
            .standardizedFileURL
        #else
        return appContainerSupportDirectoryURL(
            bundleIdentifier: appBundleIdentifier,
            homeDirectoryURL: hostHomeDirectoryURL(fileManager: fileManager)
        )
        #endif
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

    public static func executableDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL? {
        let rawExecutablePath = normalizedPath(CommandLine.arguments.first)
        let candidateURLs = [
            Bundle.main.executableURL,
            rawExecutablePath.map {
                URL(fileURLWithPath: $0)
            }
        ].compactMap { $0 }

        for candidateURL in candidateURLs {
            let executableURL = candidateURL
                .standardizedFileURL
                .resolvingSymlinksInPath()
            let directoryURL = executableURL
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            return directoryURL
        }

        return nil
    }

    private static func isAppBundleExecutableDirectory(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3 else {
            return false
        }

        let suffix = components.suffix(3)
        guard suffix.dropFirst().elementsEqual(["Contents", "MacOS"]) else {
            return false
        }
        return suffix.first?.hasSuffix(".app") == true
    }

    private static func normalizedPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    public static func appContainerSupportDirectoryURL(
        bundleIdentifier: String,
        homeDirectoryURL: URL
    ) -> URL {
        let hostHomeURL = unsandboxedHomeDirectoryURL(from: homeDirectoryURL)
            ?? homeDirectoryURL.standardizedFileURL
        return hostHomeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func hostHomeDirectoryURL(
        fileManager: FileManager
    ) -> URL {
#if os(macOS)
        if let homeURL = passwordDatabaseHomeDirectoryURL() {
            return homeURL
        }
#endif
        #if os(macOS)
        let homeURL = fileManager.homeDirectoryForCurrentUser.standardizedFileURL
        #else
        let homeURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL
        #endif
        return unsandboxedHomeDirectoryURL(from: homeURL) ?? homeURL
    }

    private static func unsandboxedHomeDirectoryURL(from url: URL) -> URL? {
        let standardizedURL = url.standardizedFileURL
        let components = standardizedURL.pathComponents
        guard components.count >= 5 else {
            return nil
        }

        for index in components.indices {
            guard index + 3 < components.count,
                  components[index] == "Library",
                  components[index + 1] == "Containers",
                  components[index + 3] == "Data" else {
                continue
            }

            let homeComponents = components[..<index]
            guard !homeComponents.isEmpty else {
                return nil
            }
            return URL(
                fileURLWithPath: NSString.path(withComponents: Array(homeComponents)),
                isDirectory: true
            ).standardizedFileURL
        }

        return nil
    }

#if os(macOS)
    private static func passwordDatabaseHomeDirectoryURL() -> URL? {
        var passwdEntry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        let suggestedBufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = max(suggestedBufferSize > 0 ? Int(suggestedBufferSize) : 0, 1024)
        var buffer = [CChar](repeating: 0, count: bufferSize)

        let status = getpwuid_r(
            getuid(),
            &passwdEntry,
            &buffer,
            buffer.count,
            &result
        )
        guard status == 0, let result, let homeDirectory = result.pointee.pw_dir else {
            return nil
        }

        let path = String(cString: homeDirectory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }
#endif
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
