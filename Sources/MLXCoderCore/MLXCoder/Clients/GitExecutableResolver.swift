//
//  GitExecutableResolver.swift
//  SwiftMLX
//
//  Created by Codex on 03/05/26.
//

import Foundation

#if canImport(Darwin) || canImport(Glibc)
public enum GitExecutableResolver {
    public static func executableURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let overridePath = environment["MLX_CODER_GIT_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty,
           FileManager.default.isExecutableFile(atPath: overridePath) {
            return URL(fileURLWithPath: overridePath)
        }

        if let gitURL = DeveloperToolEnvironment.executableURL(named: "git") {
            return gitURL
        }

        return URL(fileURLWithPath: "/usr/bin/git")
    }
}
#endif
