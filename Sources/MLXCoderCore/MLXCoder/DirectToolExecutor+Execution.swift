//
//  Split from DirectMLXAgentRuntime.swift
//  MLXCoder
//

import Foundation

extension DirectToolExecutor {
    public func executeThrowing(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> String {
        if toolCall.name == "local.exec" {
#if canImport(Darwin) || canImport(Glibc)
            return try await executeLocalExec(
                sessionID: sessionID,
                toolCall: toolCall,
                workingDirectory: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        }
        if await mcpRuntime.canExecute(toolName: toolCall.name) {
            return try await mcpRuntime.execute(toolCall: toolCall)
        }
        if let toolExecutor = toolProviderRegistry.executor(for: toolCall.name) {
            return try await toolExecutor(
                AgentToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        }
        if let borrowedOrchestrationToolExecutor,
           Self.isOrchestrationToolName(toolCall.name) {
            return try await borrowedOrchestrationToolExecutor(
                AgentBorrowedToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    argumentsJSON: toolCall.argumentsJSON
                )
            )
        }
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            return try await subAgentRuntime.execute(
                toolCall: toolCall,
                workingDirectory: workingDirectory,
                allowedToolNames: allowedToolNames
            )
        }
        if DirectOrchestrationRuntime.isTodoOrTaskToolName(toolCall.name) {
            return try await orchestrationRuntime.execute(
                sessionID: sessionID,
                toolCall: toolCall
            )
        }
        if MLXMemoryTool.isMemoryToolName(toolCall.name) {
            let request = ToolRequest(
                name: toolCall.name,
                arguments: Self.toolArguments(from: toolCall.argumentsJSON)
            )
            return try MLXMemoryTool.execute(
                request,
                context: MLXMemoryToolContext(workingDirectory: workingDirectory)
            ).text
        }

        let arguments = toolCall.argumentsObject
        switch toolCall.name {
        case "local.pwd":
            return workingDirectory.path
        case "local.ls":
            return try listDirectory(
                resolvePath(arguments.string("path") ?? ".", cwd: workingDirectory),
                includeHidden: arguments.bool("includeHidden") ?? false
            )
        case "local.readFile":
            return try readFile(
                resolvePath(arguments.string("path", "file_path") ?? "", cwd: workingDirectory),
                offset: arguments.int("offset"),
                limit: arguments.int("limit")
            )
        case "search.grep":
#if canImport(Darwin) || canImport(Glibc)
            return await grep(arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "search.glob":
            return try glob(arguments: arguments, cwd: workingDirectory)
        case "local.writeFile":
            let path = try requiredPath(arguments, cwd: workingDirectory)
            let content = arguments.string("content") ?? ""
            if arguments.bool("createDirectories") == true {
                try FileManager.default.createDirectory(
                    at: path.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            try content.write(to: path, atomically: true, encoding: .utf8)
            return "Wrote \(path.path) (\(content.utf8.count) bytes)."
        case "local.replace", "local.editFile":
            return try replace(arguments: arguments, cwd: workingDirectory)
        case "local.append":
            let path = try requiredPath(arguments, cwd: workingDirectory)
            let content = arguments.string("content") ?? ""
            let data = Data(content.utf8)
            if FileManager.default.fileExists(atPath: path.path) {
                let handle = try FileHandle(forWritingTo: path)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: path)
            }
            return "Appended \(data.count) bytes to \(path.path)."
        case "local.mkdir":
            let path = try requiredPath(arguments, cwd: workingDirectory)
            try FileManager.default.createDirectory(
                at: path,
                withIntermediateDirectories: arguments.bool("createIntermediateDirectories") ?? true
            )
            return "Created directory \(path.path)."
        case "local.delete":
            let path = try requiredPath(arguments, cwd: workingDirectory)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                return "Path does not exist: \(path.path)"
            }
            if isDirectory.boolValue && arguments.bool("recursive") != true {
                throw DirectToolError.permissionDenied("Refusing to delete directory without recursive=true.")
            }
            try FileManager.default.removeItem(at: path)
            return "Deleted \(path.path)."
        case "local.move":
            guard let source = arguments.string("sourcePath"),
                  let destination = arguments.string("destinationPath") else {
                throw DirectToolError.missingArgument("sourcePath/destinationPath")
            }
            let sourceURL = resolvePath(source, cwd: workingDirectory)
            let destinationURL = resolvePath(destination, cwd: workingDirectory)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                guard arguments.bool("overwriteExisting") == true else {
                    throw DirectToolError.permissionDenied("Destination exists. Set overwriteExisting=true.")
                }
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return "Moved \(sourceURL.path) to \(destinationURL.path)."
        case "git.status":
#if canImport(Darwin) || canImport(Glibc)
            return await runGit(["status", "--short", "--branch"], arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.diff":
#if canImport(Darwin) || canImport(Glibc)
            var gitArgs = ["diff"]
            if arguments.bool("staged", "cached") == true {
                gitArgs.append("--cached")
            }
            if let baseRevision = arguments.string("baseRevision", "base_revision", "base")?.nilIfBlank {
                gitArgs.append(baseRevision)
            }
            if let file = arguments.string("file", "file_path", "filePath")?.nilIfBlank {
                gitArgs.append("--")
                gitArgs.append(file)
            }
            return await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.show":
#if canImport(Darwin) || canImport(Glibc)
            var gitArgs = ["show", arguments.string("revision", "rev", "commit")?.nilIfBlank ?? "HEAD"]
            if let file = arguments.string("file", "file_path", "filePath")?.nilIfBlank {
                gitArgs.append("--")
                gitArgs.append(file)
            }
            return await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.log":
#if canImport(Darwin) || canImport(Glibc)
            let limit = max(1, min(arguments.int("limit", "n") ?? 20, 200))
            return await runGit(
                ["log", "--oneline", "-n", "\(limit)"],
                arguments: arguments,
                cwd: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        default:
            throw DirectToolError.unknownTool(toolCall.name)
        }
    }

#if canImport(Darwin) || canImport(Glibc)
    public func executeLocalExec(
        sessionID: String?,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> String {
        let arguments = toolCall.argumentsObject
        guard let command = arguments.string("command")?.nilIfBlank else {
            throw DirectToolError.missingArgument("command")
        }
        let cwd = resolvePath(
            arguments.string("cwd", "workingDirectory") ?? ".",
            cwd: workingDirectory
        )
        if let deniedOutput = await deniedLocalExecOutputIfNeeded(
            sessionID: sessionID,
            toolCall: toolCall,
            command: command,
            cwd: cwd
        ) {
            return deniedOutput
        }
        let timeout = TimeInterval(arguments.int("timeoutSeconds", "timeout") ?? 120)
        let result = await runProcess(
            executable: Self.defaultShellPath(),
            arguments: ["-lc", command],
            cwd: cwd,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: timeout
        )
        return renderProcessResult(result)
    }

    private static func defaultShellPath() -> String {
        #if os(Linux)
        return ProcessInfo.processInfo.environment["SHELL"]?.nilIfBlank ?? "/bin/sh"
        #else
        return ProcessInfo.processInfo.environment["SHELL"]?.nilIfBlank ?? "/bin/zsh"
        #endif
    }
#endif
}
