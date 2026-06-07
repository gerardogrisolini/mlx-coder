//
//  AgentVoiceToolRunner.swift
//  MLXCoder
//

import Foundation

public typealias AgentVoiceToolProgress = @Sendable (String) async -> Void

struct AgentVoiceToolResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum AgentVoiceToolRunner {
    static func run(
        executablePath: String,
        arguments: [String],
        progress: AgentVoiceToolProgress? = nil
    ) async throws -> AgentVoiceToolResult {
        let stdoutURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-voice-stdout-\(UUID().uuidString)")
        let stderrURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-voice-stderr-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let progressSink = progress.map(AgentVoiceProgressSink.init(progress:))
        let progressTask = progressSink.map { sink in
            Task {
                await monitorProgress(at: stderrURL, sink: sink)
            }
        }
        defer {
            progressTask?.cancel()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        let result = try await Task.detached(priority: .userInitiated) {
            let launch = launchConfiguration(
                executablePath: executablePath,
                arguments: arguments
            )
            let process = Process()
            process.executableURL = launch.executableURL
            process.arguments = launch.arguments

            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                try? stdoutHandle.close()
                try? stderrHandle.close()
                throw error
            }

            try stdoutHandle.close()
            try stderrHandle.close()

            let stdout = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
            let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
            return AgentVoiceToolResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr
            )
        }.value

        if let progressSink {
            await emitProgressLines(from: result.stderr, to: progressSink)
        }
        return result
    }

    static func progressMessage(from line: String) -> String? {
        let prefix = "[mlx-voice]"
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix(prefix) else {
            return nil
        }
        return String(trimmedLine.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    static func errorDetail(from stderr: String) -> String? {
        stderr
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { progressMessage(from: $0) == nil }
            .joined(separator: "\n")
            .nilIfBlank
    }

    private static func monitorProgress(
        at url: URL,
        sink: AgentVoiceProgressSink
    ) async {
        var offset: UInt64 = 0
        var pending = ""
        while !Task.isCancelled {
            await readProgressLines(
                at: url,
                offset: &offset,
                pending: &pending,
                sink: sink
            )
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private static func readProgressLines(
        at url: URL,
        offset: inout UInt64,
        pending: inout String,
        sink: AgentVoiceProgressSink
    ) async {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return
        }
        defer {
            try? handle.close()
        }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.readToEnd(), !data.isEmpty else {
                return
            }
            offset += UInt64(data.count)
            pending.append(String(decoding: data, as: UTF8.self))
            while let newlineRange = pending.range(of: "\n") {
                let line = String(pending[..<newlineRange.lowerBound])
                pending.removeSubrange(...newlineRange.lowerBound)
                await sink.emit(line)
            }
        } catch {
            return
        }
    }

    private static func emitProgressLines(
        from stderr: String,
        to sink: AgentVoiceProgressSink
    ) async {
        for line in stderr.split(whereSeparator: \.isNewline) {
            await sink.emit(String(line))
        }
    }

    private static func launchConfiguration(
        executablePath: String,
        arguments: [String]
    ) -> (executableURL: URL, arguments: [String]) {
        if executablePath.contains("/") {
            return (URL(fileURLWithPath: executablePath), arguments)
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), [executablePath] + arguments)
    }
}

private actor AgentVoiceProgressSink {
    private let progress: AgentVoiceToolProgress
    private var emittedMessages = Set<String>()

    init(progress: @escaping AgentVoiceToolProgress) {
        self.progress = progress
    }

    func emit(_ line: String) async {
        guard let message = AgentVoiceToolRunner.progressMessage(from: line),
              emittedMessages.insert(message).inserted else {
            return
        }
        await progress(message)
    }
}
