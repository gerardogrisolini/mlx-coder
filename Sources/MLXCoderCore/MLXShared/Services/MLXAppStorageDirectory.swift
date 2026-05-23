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
    private static let supportDirectoryName = "mlx-coder"

    public static func appSupportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        #if os(Linux)
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".mlx-coder", isDirectory: true)
            .standardizedFileURL
        #else
        appContainerSupportDirectoryURL(
            bundleIdentifier: appBundleIdentifier,
            homeDirectoryURL: hostHomeDirectoryURL(fileManager: fileManager)
        )
        #endif
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
