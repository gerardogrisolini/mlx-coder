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

public extension MLXCoderACPBridge {
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

    public static func metricsUpdate(
        for metrics: DirectAgentGenerationMetrics
    ) -> [String: Any] {
        var update: [String: Any] = [
            "sessionUpdate": "metrics_update",
        ]
        if let promptTokenCount = metrics.promptTokenCount {
            update["promptTokenCount"] = promptTokenCount
        }
        if let cachedPromptTokenCount = metrics.cachedPromptTokenCount {
            update["cachedPromptTokenCount"] = cachedPromptTokenCount
        }
        if let totalTokenCount = metrics.totalTokenCount {
            update["totalTokenCount"] = totalTokenCount
        }
        if let promptTokensPerSecond = metrics.promptTokensPerSecond {
            update["promptTokensPerSecond"] = promptTokensPerSecond
        }
        if let completionTokenCount = metrics.completionTokenCount {
            update["completionTokenCount"] = completionTokenCount
        }
        if let completionTokensPerSecond = metrics.completionTokensPerSecond {
            update["completionTokensPerSecond"] = completionTokensPerSecond
        }
        if let responseDurationSeconds = metrics.responseDurationSeconds {
            update["responseDurationSeconds"] = responseDurationSeconds
        }
        return update
    }

    public static func contextWindowUpdate(
        for status: DirectAgentContextWindowStatus
    ) -> [String: Any] {
        var update: [String: Any] = [
            "sessionUpdate": "context_window_update",
            "modelID": status.modelID,
            "isApproximate": status.isApproximate
        ]
        if let usedTokens = status.usedTokens {
            update["usedTokens"] = usedTokens
        }
        if let maxTokens = status.maxTokens {
            update["maxTokens"] = maxTokens
        }
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
             "git.status", "git.diff", "git.show", "git.log":
            return "read"
        case "search.grep", "search.glob":
            return "search"
        case "local.writeFile", "local.replace", "local.append", "local.mkdir":
            return "edit"
        case "local.delete":
            return "delete"
        case "local.move":
            return "move"
        case "local.exec":
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
        return candidateKeys.compactMap { key in
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
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.withoutEscapingSlashes, .sortedKeys]
              ) else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    public static func isAppSuppressedDiagnostic(_ message: String) -> Bool {
        isMetricsDiagnostic(message)
            || message.hasPrefix("Remote request:")
    }

    public static func isMetricsDiagnostic(_ message: String) -> Bool {
        message.hasPrefix("Generation done:")
    }
}
