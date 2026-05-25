//
//  MLXMetalLibraryBootstrap.swift
//  mlx-server
//

import Foundation
#if os(macOS)
import Darwin
#endif

enum MLXMetalLibraryBootstrap {
    static func prepareIfNeeded() throws {
        #if os(macOS)
        setenv("MLX_METAL_FAST_SYNCH", "1", 0)

        let outputURL = try executableDirectory().appendingPathComponent("mlx.metallib")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return
        }

        let sourceURL = try findGeneratedMetalDirectory()
        try compileGeneratedMetalKernels(from: sourceURL, to: outputURL)
        #endif
    }

    #if os(macOS)
    private static func executableDirectory() throws -> URL {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer {
            buffer.deallocate()
        }

        guard _NSGetExecutablePath(buffer, &size) == 0 else {
            throw MLXMetalLibraryBootstrapError.missingExecutableURL
        }

        return URL(fileURLWithPath: String(cString: buffer))
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
    }

    private static func findGeneratedMetalDirectory() throws -> URL {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let executableDirectory = try executableDirectory()

        let roots = ancestorURLs(startingAt: currentDirectory)
            + ancestorURLs(startingAt: executableDirectory)

        for root in roots {
            let candidate = root
                .appendingPathComponent(".build/checkouts/mlx-swift/Source/Cmlx/mlx-generated/metal")
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw MLXMetalLibraryBootstrapError.missingGeneratedMetalDirectory
    }

    private static func ancestorURLs(startingAt url: URL) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL

        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return result
            }
            current = parent
        }
    }

    private static func compileGeneratedMetalKernels(from sourceURL: URL, to outputURL: URL) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("mlx-server-metal-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let metalFiles = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "metal" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !metalFiles.isEmpty else {
            throw MLXMetalLibraryBootstrapError.noMetalSources(sourceURL.path)
        }

        var airFiles: [URL] = []
        for metalFile in metalFiles {
            let airFile = temporaryDirectory
                .appendingPathComponent(metalFile.deletingPathExtension().lastPathComponent)
                .appendingPathExtension("air")
            try runXcrun([
                "-sdk", "macosx",
                "metal",
                "-x", "metal",
                "-Wall",
                "-Wextra",
                "-fno-fast-math",
                "-Wno-c++17-extensions",
                "-Wno-c++20-extensions",
                "-c", metalFile.path,
                "-I", sourceURL.path,
                "-o", airFile.path
            ])
            airFiles.append(airFile)
        }

        try runXcrun([
            "-sdk", "macosx",
            "metallib"
        ] + airFiles.map(\.path) + [
            "-o", outputURL.path
        ])
    }

    private static func runXcrun(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
            throw MLXMetalLibraryBootstrapError.xcrunFailed(arguments.joined(separator: " "), output ?? "")
        }
    }
    #endif
}

enum MLXMetalLibraryBootstrapError: LocalizedError {
    case missingExecutableURL
    case missingGeneratedMetalDirectory
    case noMetalSources(String)
    case xcrunFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingExecutableURL:
            "Unable to resolve mlx-server executable path."
        case .missingGeneratedMetalDirectory:
            "Unable to find mlx-swift generated Metal sources under .build/checkouts."
        case .noMetalSources(let path):
            "No Metal source files found in \(path)."
        case .xcrunFailed(let command, let output):
            "xcrun failed while running \(command): \(output)"
        }
    }
}
