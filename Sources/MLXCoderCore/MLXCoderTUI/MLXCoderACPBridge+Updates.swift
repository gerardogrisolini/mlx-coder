//
//  Generated split from MLXCoderACPBridge.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension MLXCoderACPBridge {
    public func sendUserMessageChunk(sessionID: String, text: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: JSONValue.acpValue(from: [
                "sessionUpdate": "user_message_chunk",
                "content": [
                    "type": "text",
                    "text": text
                ]
            ])
        )
    }

    public func sendSessionInfoUpdate(sessionID: String, title: String) async {
        await writer.sendSessionUpdate(
            sessionID: sessionID,
            update: JSONValue.acpValue(from: [
                "sessionUpdate": "session_info_update",
                "title": title,
                "updatedAt": ISO8601DateFormatter().string(from: Date())
            ])
        )
    }

    public func promptTitle(from prompt: String) -> String {
        let firstLine = prompt
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "mlx-coder session"
        if firstLine.count <= 80 {
            return firstLine
        }
        return "\(firstLine.prefix(77))..."
    }

    public static func toolCallCreateUpdate(
        for toolCall: DirectAgentToolCall
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall.name),
            "status": "pending",
            "rawInput": toolCall.argumentsObject,
            "content": [] as [Any],
            "locations": toolLocations(for: toolCall)
        ]
    }

    public static func usageUpdate(
        for status: DirectAgentContextWindowStatus
    ) -> [String: Any]? {
        guard let usedTokens = status.usedTokens,
              let maxTokens = status.maxTokens else {
            return nil
        }
        let used = max(0, usedTokens)
        let size = max(used, maxTokens)
        let update: [String: Any] = [
            "sessionUpdate": "usage_update",
            "used": used,
            "size": size,
            "_meta": [
                "modelID": status.modelID,
                "isApproximate": status.isApproximate
            ]
        ]
        return update
    }

    public static func toolCallProgressUpdate(
        for toolCall: DirectAgentToolCall
    ) -> [String: Any] {
        [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "status": "in_progress",
            "rawInput": toolCall.argumentsObject,
            "locations": toolLocations(for: toolCall)
        ]
    }

    public static func toolCallCompletionUpdate(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> [String: Any] {
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        return [
            "sessionUpdate": "tool_call_update",
            "toolCallId": toolCall.id,
            "title": toolTitle(for: toolCall),
            "kind": toolKind(for: toolCall.name),
            "status": failed ? "failed" : "completed",
            "rawInput": toolCall.argumentsObject,
            "rawOutput": [
                "output": result.output,
                "summary": result.summary
            ],
            "content": [
                [
                    "type": "content",
                    "content": [
                        "type": "text",
                        "text": result.output
                    ]
                ]
            ],
            "locations": toolLocations(for: toolCall)
        ]
    }

    public static func toolTitle(for toolCall: DirectAgentToolCall) -> String {
        switch toolKind(for: toolCall.name) {
        case "read":
            return "Read \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "edit":
            return "Edit \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "delete":
            return "Delete \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "move":
            return "Move \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "search":
            return "Search \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        case "execute":
            return "Run \(displayToolTarget(for: toolCall) ?? toolCall.name)"
        default:
            return toolCall.name
        }
    }

    public static func toolKind(for toolName: String) -> String {
        switch toolName {
        case "local.readFile", "local.ls", "local.pwd",
             "text.head", "text.tail", "text.sort", "text.wc",
             "git.status", "git.diff", "git.show", "git.log",
             "git.branch", "git.remote", "git.lsFiles", "git.grep", "git.blame":
            return "read"
        case "search.grep", "search.glob":
            return "search"
        case "local.writeFile", "local.replace", "local.append", "local.mkdir":
            return "edit"
        case "local.delete":
            return "delete"
        case "local.move":
            return "move"
        case "local.exec", "git.add", "git.restore", "git.commit", "git.stash", "git.switch":
            return "execute"
        case "agent.list", "agent.get", "agent.wait":
            return "read"
        case "agent.create", "agent.message", "agent.close":
            return "execute"
        default:
            if toolName.hasPrefix("xcode.") {
                return xcodeToolKind(for: String(toolName.dropFirst("xcode.".count)))
            }
            if toolName.hasPrefix("figma.") {
                return "read"
            }
            return "other"
        }
    }

    public static func xcodeToolKind(for rawName: String) -> String {
        switch rawName {
        case "XcodeUpdate", "XcodeWrite", "XcodeMakeDir":
            return "edit"
        case "XcodeRM":
            return "delete"
        case "XcodeMV":
            return "move"
        case "BuildProject", "RunAllTests", "RunSomeTests", "ExecuteSnippet", "RenderPreview":
            return "execute"
        case "XcodeGrep", "XcodeGlob", "DocumentationSearch":
            return "search"
        default:
            return "read"
        }
    }

    public static func toolLocations(for toolCall: DirectAgentToolCall) -> [[String: Any]] {
        let candidateKeys = [
            "path",
            "file_path",
            "sourcePath",
            "destinationPath",
            "workingDirectory",
            "cwd",
            "filePath",
            "sourceFilePath",
            "directoryPath"
        ]
        var seen = Set<String>()
        let locations = candidateKeys.compactMap { key -> [String: Any]? in
            guard let rawPath = toolCall.argumentsObject[key] as? String,
                  let path = rawPath.nilIfBlank else {
                return nil
            }
            let normalizedPath = URL(fileURLWithPath: path)
                .standardizedFileURL
                .path
            guard seen.insert(normalizedPath).inserted else {
                return nil
            }
            return ["path": normalizedPath]
        }
        return locations.filter { location in
            guard let path = location["path"] as? String else {
                return true
            }
            return !locations.contains { candidate in
                guard let candidatePath = candidate["path"] as? String else {
                    return false
                }
                return isAncestorLocation(path, of: candidatePath)
            }
        }
    }

    private static func isAncestorLocation(
        _ ancestorPath: String,
        of descendantPath: String
    ) -> Bool {
        let ancestor = URL(fileURLWithPath: ancestorPath)
            .standardizedFileURL
            .path
        let descendant = URL(fileURLWithPath: descendantPath)
            .standardizedFileURL
            .path
        guard ancestor != descendant else {
            return false
        }
        guard ancestor != "/" else {
            return descendant.hasPrefix("/")
        }
        return descendant.hasPrefix("\(ancestor)/")
    }

    public static func displayToolTarget(for toolCall: DirectAgentToolCall) -> String? {
        let candidateKeys = [
            "path",
            "file_path",
            "sourcePath",
            "destinationPath",
            "filePath",
            "sourceFilePath",
            "directoryPath",
            "command",
            "pattern"
        ]
        return candidateKeys.lazy.compactMap { key in
            (toolCall.argumentsObject[key] as? String)?.nilIfBlank
        }.first
    }

    public static func compactJSONString(from value: Any) -> String? {
        JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }

    public static func isAppSuppressedDiagnostic(_ message: String) -> Bool {
        isMetricsDiagnostic(message)
            || message.hasPrefix("Remote request:")
    }

    public static func isMetricsDiagnostic(_ message: String) -> Bool {
        message.hasPrefix("Generation done:")
    }
}
