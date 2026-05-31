//
//  Split from DirectMLXAgentRuntime.swift
//  MLXCoder
//

import Foundation

extension DirectToolExecutor {
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

    public func resolvePath(_ path: String, cwd: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return cwd.appendingPathComponent(expanded).standardizedFileURL
    }

#if canImport(Darwin) || canImport(Glibc)
    public func deniedGitMutationOutputIfNeeded(
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
                toolName: toolCall.name,
                title: "Run \(command)",
                kind: "git.mutation",
                command: command,
                workingDirectory: cwd.path
            )
        )
        guard !approved else {
            return nil
        }

        return """
        Git command cancelled.
        The user did not approve this `\(toolCall.name)` request, so no git command was run.

        Working directory:
        \(cwd.path)

        Command:
        \(command)
        """
    }

    public func deniedSwiftFeatureToolOutputIfNeeded(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async -> String? {
        guard toolCall.name.hasPrefix("git."),
              let authorization = try? gitFeatureMutationAuthorization(
                  toolCall: toolCall,
                  cwd: workingDirectory
              ) else {
            return nil
        }
        return await deniedGitMutationOutputIfNeeded(
            sessionID: sessionID,
            toolCall: toolCall,
            command: authorization.command,
            cwd: authorization.cwd
        )
    }

    private func gitFeatureMutationAuthorization(
        toolCall: DirectAgentToolCall,
        cwd: URL
    ) throws -> (command: String, cwd: URL)? {
        let arguments = toolCall.argumentsObject
        let gitCwd = gitWorkingDirectory(arguments: arguments, cwd: cwd)
        let gitArguments: [String]
        switch toolCall.name {
        case "git.add":
            var args = ["add"]
            if arguments.bool("all") == true {
                args.append("-A")
            } else if let paths = arguments.stringArray("paths", "path"), !paths.isEmpty {
                args.append("--")
                args.append(contentsOf: paths)
            } else {
                return nil
            }
            gitArguments = args
        case "git.restore":
            let staged = arguments.bool("staged") == true
            let worktree = arguments.bool("worktree") == true
            guard staged || worktree else {
                return nil
            }
            var args = ["restore"]
            if staged {
                args.append("--staged")
            }
            if worktree {
                args.append("--worktree")
            }
            args.append("--")
            args.append(contentsOf: arguments.stringArray("paths", "path") ?? ["."])
            gitArguments = args
        case "git.commit":
            guard let message = arguments.string("message")?.nilIfBlank else {
                return nil
            }
            var args = ["commit", "-m", message]
            if arguments.bool("all") == true {
                args.insert("-a", at: 1)
            }
            gitArguments = args
        case "git.stash":
            let action = (arguments.string("action")?.nilIfBlank ?? "list").lowercased()
            guard !["list", "show"].contains(action) else {
                return nil
            }
            gitArguments = try gitStashArguments(action: action, arguments: arguments)
        case "git.switch":
            guard let branch = arguments.string("branch")?.nilIfBlank else {
                return nil
            }
            var args = ["switch"]
            if arguments.bool("create") == true {
                args.append("-c")
            }
            args.append(branch)
            gitArguments = args
        default:
            return nil
        }
        return (Self.renderShellCommand(["git"] + gitArguments), gitCwd)
    }

    private func gitStashArguments(
        action: String,
        arguments: [String: Any]
    ) throws -> [String] {
        switch action {
        case "list":
            return ["stash", "list"]
        case "show":
            return ["stash", "show", "--stat", "--patch", arguments.string("stash")?.nilIfBlank ?? "stash@{0}"]
        case "push", "save":
            var gitArgs = ["stash", "push"]
            if let message = arguments.string("message")?.nilIfBlank {
                gitArgs.append(contentsOf: ["-m", message])
            }
            if arguments.bool("includeUntracked") == true {
                gitArgs.append("--include-untracked")
            }
            if let paths = arguments.stringArray("paths", "path"), !paths.isEmpty {
                gitArgs.append("--")
                gitArgs.append(contentsOf: paths)
            }
            return gitArgs
        case "apply", "pop", "drop":
            var gitArgs = ["stash", action]
            if let stash = arguments.string("stash")?.nilIfBlank {
                gitArgs.append(stash)
            }
            return gitArgs
        default:
            throw DirectToolError.permissionDenied("Unsupported git stash action: \(action).")
        }
    }

    public func gitWorkingDirectory(arguments: [String: Any], cwd: URL) -> URL {
        resolvePath(
            arguments.string("workingDirectory", "cwd", "repoPath", "repo_path", "repositoryPath", "repository_path") ?? ".",
            cwd: cwd
        )
    }

    public static func renderShellCommand(_ words: [String]) -> String {
        words.map { word in
            guard !word.isEmpty,
                  word.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\"'\\$`!"))) == nil else {
                return "'\(word.replacingOccurrences(of: "'", with: "'\\''"))'"
            }
            return word
        }.joined(separator: " ")
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
