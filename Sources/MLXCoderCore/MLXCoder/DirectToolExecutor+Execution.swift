//
//  Split from DirectMLXAgentRuntime.swift
//  MLXCoder
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        case "text.head":
            return try head(arguments: arguments, cwd: workingDirectory)
        case "text.tail":
            return try tail(arguments: arguments, cwd: workingDirectory)
        case "text.sort":
            return try sortText(arguments: arguments, cwd: workingDirectory)
        case "text.wc":
            return try wordCount(arguments: arguments, cwd: workingDirectory)
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
        case "local.replace":
            return try replaceAll(arguments: arguments, cwd: workingDirectory)
        case "local.editFile":
            return try replace(arguments: arguments, cwd: workingDirectory)
        case "local.multiEdit":
            return try multiEdit(arguments: arguments, cwd: workingDirectory)
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
            if let file = arguments.string("file", "file_path", "filePath", "path")?.nilIfBlank {
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
            if let file = arguments.string("file", "file_path", "filePath", "path")?.nilIfBlank {
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
        case "git.branch":
#if canImport(Darwin) || canImport(Glibc)
            var gitArgs = ["branch"]
            if arguments.bool("all") == true {
                gitArgs.append("--all")
            } else if arguments.bool("remotes") == true {
                gitArgs.append("--remotes")
            }
            if let contains = arguments.string("contains")?.nilIfBlank {
                gitArgs.append(contentsOf: ["--contains", contains])
            }
            return await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.remote":
#if canImport(Darwin) || canImport(Glibc)
            return await runGit(["remote", "-v"], arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.lsFiles":
#if canImport(Darwin) || canImport(Glibc)
            var gitArgs = ["ls-files"]
            if arguments.bool("includeUntracked") == true {
                gitArgs.append(contentsOf: ["--cached", "--others", "--exclude-standard"])
            }
            let output = await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
            let maxResults = max(1, min(arguments.int("maxResults", "max_results") ?? 500, 10_000))
            return output.components(separatedBy: .newlines)
                .prefix(maxResults)
                .joined(separator: "\n")
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.grep":
#if canImport(Darwin) || canImport(Glibc)
            guard let pattern = arguments.string("pattern")?.nilIfBlank else {
                throw DirectToolError.missingArgument("pattern")
            }
            let maxResults = max(1, min(arguments.int("maxResults", "max_results") ?? 200, 10_000))
            var gitArgs = ["grep", "-n", "-I", "-m", "\(maxResults)", pattern]
            if let paths = arguments.stringArray("paths", "path"), !paths.isEmpty {
                gitArgs.append("--")
                gitArgs.append(contentsOf: paths)
            }
            return await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.blame":
#if canImport(Darwin) || canImport(Glibc)
            guard let file = arguments.string("file", "path", "file_path")?.nilIfBlank else {
                throw DirectToolError.missingArgument("file")
            }
            var gitArgs = ["blame"]
            if let startLine = arguments.int("startLine"),
               let endLine = arguments.int("endLine") {
                gitArgs.append(contentsOf: ["-L", "\(startLine),\(endLine)"])
            }
            gitArgs.append("--")
            gitArgs.append(file)
            return await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.add":
#if canImport(Darwin) || canImport(Glibc)
            var gitArgs = ["add"]
            if arguments.bool("all") == true {
                gitArgs.append("-A")
            } else if let paths = arguments.stringArray("paths", "path"), !paths.isEmpty {
                gitArgs.append("--")
                gitArgs.append(contentsOf: paths)
            } else {
                throw DirectToolError.missingArgument("paths")
            }
            return await runAuthorizedGit(
                sessionID: sessionID,
                toolCall: toolCall,
                gitArguments: gitArgs,
                arguments: arguments,
                cwd: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.restore":
#if canImport(Darwin) || canImport(Glibc)
            let staged = arguments.bool("staged") == true
            let worktree = arguments.bool("worktree") == true
            guard staged || worktree else {
                throw DirectToolError.missingArgument("staged or worktree")
            }
            if worktree && arguments.bool("discardChanges") != true {
                throw DirectToolError.permissionDenied("Refusing to discard worktree changes without discardChanges=true.")
            }
            let paths = arguments.stringArray("paths", "path") ?? ["."]
            var gitArgs = ["restore"]
            if staged {
                gitArgs.append("--staged")
            }
            if worktree {
                gitArgs.append("--worktree")
            }
            gitArgs.append("--")
            gitArgs.append(contentsOf: paths)
            return await runAuthorizedGit(
                sessionID: sessionID,
                toolCall: toolCall,
                gitArguments: gitArgs,
                arguments: arguments,
                cwd: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.commit":
#if canImport(Darwin) || canImport(Glibc)
            guard let message = arguments.string("message")?.nilIfBlank else {
                throw DirectToolError.missingArgument("message")
            }
            var gitArgs = ["commit", "-m", message]
            if arguments.bool("all") == true {
                gitArgs.insert("-a", at: 1)
            }
            return await runAuthorizedGit(
                sessionID: sessionID,
                toolCall: toolCall,
                gitArguments: gitArgs,
                arguments: arguments,
                cwd: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.stash":
#if canImport(Darwin) || canImport(Glibc)
            let action = (arguments.string("action")?.nilIfBlank ?? "list").lowercased()
            let gitArgs = try gitStashArguments(action: action, arguments: arguments)
            if ["list", "show"].contains(action) {
                return await runGit(gitArgs, arguments: arguments, cwd: workingDirectory)
            }
            return await runAuthorizedGit(
                sessionID: sessionID,
                toolCall: toolCall,
                gitArguments: gitArgs,
                arguments: arguments,
                cwd: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "git.switch":
#if canImport(Darwin) || canImport(Glibc)
            guard let branch = arguments.string("branch")?.nilIfBlank else {
                throw DirectToolError.missingArgument("branch")
            }
            var gitArgs = ["switch"]
            if arguments.bool("create") == true {
                gitArgs.append("-c")
            }
            gitArgs.append(branch)
            return await runAuthorizedGit(
                sessionID: sessionID,
                toolCall: toolCall,
                gitArguments: gitArgs,
                arguments: arguments,
                cwd: workingDirectory
            )
#else
            throw DirectToolError.unknownTool(toolCall.name)
#endif
        case "web.search":
            return try await searchWeb(arguments: arguments)
        case "web.fetch":
            return try await fetchWebURL(arguments: arguments)
        default:
            throw DirectToolError.unknownTool(toolCall.name)
        }
    }

    private func searchWeb(arguments: [String: Any]) async throws -> String {
        guard let query = arguments.string("query")?.nilIfBlank else {
            throw DirectToolError.missingArgument("query")
        }

        let limit = max(1, min(arguments.int("limit") ?? 5, 10))
        let domains = Self.normalizedWebDomains(from: arguments["domains"])
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "kl", value: "wt-wt")
        ]
        guard let url = components.url else {
            throw DirectToolError.permissionDenied("Unable to build the web search request.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("mlx-coder/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validateWebHTTPResponse(response)

        let html = String(decoding: data, as: UTF8.self)
        let results = Self.parseDuckDuckGoHTMLResults(
            html,
            limit: limit,
            domains: domains
        )
        guard !results.isEmpty else {
            return "Query: \(query)\nNo public web results found."
        }

        let renderedResults = results.enumerated().map { index, result in
            var lines = [
                "\(index + 1). \(result.title)",
                "   URL: \(result.url)"
            ]
            if !result.snippet.isEmpty {
                lines.append("   Snippet: \(result.snippet)")
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")

        return "Query: \(query)\n\(renderedResults)"
    }

    private func fetchWebURL(arguments: [String: Any]) async throws -> String {
        guard let rawURL = arguments.string("url")?.nilIfBlank,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            throw DirectToolError.missingArgument("url")
        }

        let maxBytes = max(1_024, min(arguments.int("maxBytes") ?? 120_000, 1_000_000))
        let timeout = TimeInterval(max(1, min(arguments.int("timeoutSeconds") ?? 20, 120)))
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("mlx-coder/1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        try Self.validateWebHTTPResponse(response)
        let bodyData = Data(data.prefix(maxBytes))
        let body = String(data: bodyData, encoding: .utf8)
            ?? "<non-UTF-8 response body: \(bodyData.count) bytes>"
        let truncatedSuffix = data.count > bodyData.count
            ? "\n\n<truncated: \(data.count - bodyData.count) bytes omitted>"
            : ""

        return """
        url: \(response.url?.absoluteString ?? url.absoluteString)
        status: \(httpResponse?.statusCode ?? 0)
        content-type: \(httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown")
        bytes: \(data.count)

        \(body)\(truncatedSuffix)
        """
    }

    private static func validateWebHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DirectToolError.permissionDenied("The web response was not an HTTP response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw DirectToolError.permissionDenied("The web request failed with HTTP status \(httpResponse.statusCode).")
        }
    }

    private static func normalizedWebDomains(from value: Any?) -> [String] {
        let rawDomains: [String]
        if let domains = value as? [String] {
            rawDomains = domains
        } else if let domains = value as? [Any] {
            rawDomains = domains.compactMap { $0 as? String }
        } else {
            rawDomains = []
        }
        return rawDomains
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { !$0.isEmpty }
    }

    private static func parseDuckDuckGoHTMLResults(
        _ html: String,
        limit: Int,
        domains: [String]
    ) -> [DirectWebSearchResult] {
        let anchorPattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<(?:a|div)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|div)>"#

        guard let anchorRegex = try? NSRegularExpression(
            pattern: anchorPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let snippetRegex = try? NSRegularExpression(
            pattern: snippetPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = anchorRegex.matches(in: html, options: [], range: nsRange)
        var results: [DirectWebSearchResult] = []
        for (index, match) in matches.enumerated() {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let resultURL = resolvedWebSearchResultURL(from: String(html[hrefRange])),
                  isAllowedWebSearchResultURL(resultURL, domains: domains) else {
                continue
            }

            let title = normalizeWebText(stripWebHTML(String(html[titleRange])))
            guard !title.isEmpty else {
                continue
            }

            let lowerBound = match.range.location + match.range.length
            let upperBound = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.location + nsRange.length
            let searchRange = NSRange(location: lowerBound, length: max(upperBound - lowerBound, 0))
            let snippet: String
            if let snippetRegex,
               let snippetMatch = snippetRegex.firstMatch(in: html, options: [], range: searchRange),
               let snippetRange = Range(snippetMatch.range(at: 1), in: html) {
                snippet = normalizeWebText(stripWebHTML(String(html[snippetRange])))
            } else {
                snippet = ""
            }

            results.append(
                DirectWebSearchResult(
                    title: title,
                    url: resultURL.absoluteString,
                    snippet: snippet
                )
            )
            if results.count >= limit {
                break
            }
        }
        return results
    }

    private static func resolvedWebSearchResultURL(from rawHref: String) -> URL? {
        let href = decodeWebHTMLEntities(rawHref)
        let normalizedHref = href.hasPrefix("//") ? "https:\(href)" : href
        guard let url = URL(string: normalizedHref) else {
            return nil
        }
        if let host = url.host?.lowercased(),
           host.contains("duckduckgo.com"),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let encodedTarget = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let decodedTarget = encodedTarget.removingPercentEncoding,
           let targetURL = URL(string: decodedTarget) {
            return targetURL
        }
        return url
    }

    private static func isAllowedWebSearchResultURL(_ url: URL, domains: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        guard !domains.isEmpty else {
            return true
        }
        return domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func stripWebHTML(_ text: String) -> String {
        replaceWebPattern(text, pattern: #"<[^>]+>"#, with: " ")
    }

    private static func normalizeWebText(_ text: String) -> String {
        decodeWebHTMLEntities(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replaceWebPattern(_ text: String, pattern: String, with replacement: String) -> String {
        (try? NSRegularExpression(pattern: pattern, options: []))?
            .stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: replacement
            ) ?? text
    }

    private static func decodeWebHTMLEntities(_ text: String) -> String {
        var decoded = text
        let replacements = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]
        for (entity, replacement) in replacements {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement)
        }
        return decoded
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

private struct DirectWebSearchResult {
    let title: String
    let url: String
    let snippet: String
}
