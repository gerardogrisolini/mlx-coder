//
//  Split from DirectMLXAgentRuntime.swift
//  MLXCoder
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public extension DirectToolExecutor {
    public func deniedLocalExecOutputIfNeeded(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        command: String,
        cwd: URL
    ) async -> String? {
        guard let authorizationHandler else {
            return nil
        }

        let approved = await authorizationHandler(
            AgentToolAuthorizationRequest(
                sessionID: sessionID,
                toolCallID: toolCall.id,
                toolName: "local.exec",
                title: "Run \(command)",
                kind: "execute",
                command: command,
                workingDirectory: cwd.path
            )
        )
        guard !approved else {
            return nil
        }

        return """
        Command execution cancelled.
        The user did not approve this `local.exec` request, so no shell command was run.

        Working directory:
        \(cwd.path)

        Command:
        \(command)
        """
    }

    public func requiredPath(_ arguments: [String: Any], cwd: URL) throws -> URL {
        guard let path = arguments.string("path", "file_path")?.nilIfBlank else {
            throw DirectToolError.missingArgument("path")
        }
        return resolvePath(path, cwd: cwd)
    }

    public func resolvePath(_ path: String, cwd: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return cwd.appendingPathComponent(expanded).standardizedFileURL
    }

    public func listDirectory(_ url: URL, includeHidden: Bool) throws -> String {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        guard !entries.isEmpty else {
            return "<empty>"
        }
        return try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry in
                let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return isDirectory ? "\(entry.lastPathComponent)/" : entry.lastPathComponent
            }
            .joined(separator: "\n")
    }

    public func readFile(_ url: URL, offset: Int?, limit: Int?) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let startIndex = max((offset ?? 1) - 1, 0)
        let endIndex = min(
            lines.count,
            startIndex + max(limit ?? min(lines.count, 240), 1)
        )
        guard startIndex < endIndex else {
            return "<empty>"
        }
        return (startIndex..<endIndex)
            .map { index in "\(index + 1)\t\(lines[index])" }
            .joined(separator: "\n")
    }

#if canImport(Darwin) || canImport(Glibc)
    public func grep(arguments: [String: Any], cwd: URL) async -> String {
        guard let pattern = arguments.string("pattern")?.nilIfBlank else {
            return "Tool error: missing pattern."
        }
        let path = resolvePath(arguments.string("path") ?? ".", cwd: cwd)
        let maxResults = max(1, arguments.int("maxResults", "max_results") ?? 200)
        var processArguments = ["-E", "-R", "-n", "-I"]
        if maxResults < 10000 {
            processArguments.append(contentsOf: ["-m", "\(maxResults)"])
        }
        processArguments.append(pattern)
        processArguments.append(path.path)
        let result = await runProcess(
            executable: "/usr/bin/grep",
            arguments: processArguments,
            cwd: cwd,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 60
        )
        if result.status == 1,
           result.stdout.isEmpty,
           result.stderr.isEmpty {
            return "No matches found."
        }
        let rendered = renderProcessResult(result)
        return rendered.components(separatedBy: .newlines)
            .prefix(maxResults)
            .joined(separator: "\n")
    }
#endif

    public func glob(arguments: [String: Any], cwd: URL) throws -> String {
        guard let pattern = arguments.string("pattern")?.nilIfBlank else {
            throw DirectToolError.missingArgument("pattern")
        }
        let root = resolvePath(arguments.string("path") ?? ".", cwd: cwd)
        let maxResults = max(1, arguments.int("maxResults", "max_results") ?? 200)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return "<empty>"
        }
        var matches: [String] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else {
                continue
            }
            if fnmatch(pattern, relative, 0) == 0 || fnmatch(pattern, url.lastPathComponent, 0) == 0 {
                matches.append(relative)
                if matches.count >= maxResults {
                    break
                }
            }
        }
        return matches.isEmpty ? "<empty>" : matches.joined(separator: "\n")
    }

    public func replace(arguments: [String: Any], cwd: URL) throws -> String {
        let path = try requiredPath(arguments, cwd: cwd)
        guard let oldString = arguments.string("oldString", "old_string") else {
            throw DirectToolError.missingArgument("oldString")
        }
        let newString = arguments.string("newString", "new_string") ?? ""
        let replaceAll = arguments.bool("replaceAll", "replace_all") ?? false
        let original = try String(contentsOf: path, encoding: .utf8)
        let occurrences = original.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            throw DirectToolError.permissionDenied("oldString was not found in \(path.path).")
        }
        if !replaceAll && occurrences != 1 {
            throw DirectToolError.permissionDenied("oldString matched \(occurrences) times. Set replaceAll=true or provide a unique string.")
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return "Updated \(path.path). Replacements: \(replaceAll ? occurrences : 1)."
    }

#if canImport(Darwin) || canImport(Glibc)
    public func runGit(_ gitArguments: [String], arguments: [String: Any], cwd: URL) async -> String {
        let gitCwd = resolvePath(arguments.string("workingDirectory", "cwd", "repo_path", "repository_path", "path") ?? ".", cwd: cwd)
        let result = await runProcess(
            executable: GitExecutableResolver.executableURL().path,
            arguments: gitArguments,
            cwd: gitCwd,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 60
        )
        return renderProcessResult(result)
    }

    public func runProcess(
        executable: String,
        arguments: [String],
        cwd: URL,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) async -> ProcessResult {
        do {
            let result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                workingDirectory: cwd,
                environment: environment,
                timeout: timeout
            )
            return ProcessResult(
                status: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                timedOut: result.timedOut
            )
        } catch {
            return ProcessResult(
                status: -1,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }
    }
#endif

    public func renderProcessResult(_ result: ProcessResult) -> String {
        var sections = ["exit_code: \(result.status)"]
        if result.timedOut {
            sections.append("timed_out: true")
        }
        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stdout:\n\(result.stdout)")
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stderr:\n\(result.stderr)")
        }
        if sections.count == 1 {
            sections.append("<no output>")
        }
        return sections.joined(separator: "\n")
    }

    public static func toolArguments(from argumentsJSON: String) -> [String: JSONValue] {
        let trimmedJSON = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedJSON.isEmpty,
              let data = trimmedJSON.data(using: .utf8),
              let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            return [:]
        }
        return arguments
    }

    public func truncated(_ text: String) -> String {
        guard text.count > outputLimit else {
            return text
        }
        return String(text.prefix(outputLimit)) + "\n... truncated to \(outputLimit) characters ..."
    }

    public func summary(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "<no output>"
        }
        return String(trimmed.components(separatedBy: .newlines).first?.prefix(160) ?? "")
    }

    public static func canonicalized(
        _ descriptors: [DirectToolDescriptor]
    ) -> [DirectToolDescriptor] {
        var seen = Set<String>()
        return descriptors.filter { descriptor in
            seen.insert(descriptor.name).inserted
        }
    }
}
