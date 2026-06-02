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
    public func initialize(id: JSONValue?, params: [String: Any]) async throws {
        let protocolVersion = 1
        let result: [String: Any] = [
            "protocolVersion": protocolVersion,
            "agentCapabilities": [
                "loadSession": false,
                "promptCapabilities": [
                    "image": true,
                    "audio": false,
                    "embeddedContext": true
                ],
                "mcpCapabilities": [
                    "http": false,
                    "sse": false
                ],
                "sessionCapabilities": [
                    "close": [:]
                ]
            ],
            "agentInfo": [
                "name": "mlx-coder",
                "title": "mlx-coder",
                "version": agentVersion
            ],
            "authMethods": []
        ]
        await writer.sendResultIfRequest(id: id, result: JSONValue.acpValue(from: result))
    }

    public func preloadModel(id: JSONValue?, params: [String: Any]) async throws {
        _ = params
        let modelID = try await sessionRunner.preloadModel(
            configuration: defaultSessionConfiguration(sessionID: "preload")
        ) { _ in }
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: ["modelID": modelID])
        )
    }

    public func newSession(id: JSONValue?, params: [String: Any]) async throws {
        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let cwd = AgentConfiguration.resolvedWorkingDirectory(rawValue: rawCwd).path

        let sessionID = "swiftmlx-\(UUID().uuidString.lowercased())"
        let cacheKey = (params["sessionKey"] as? String)
            ?? (params["cacheKey"] as? String)
        let allowedToolNames = Self.allowedToolNames(from: params["allowedTools"])
            ?? configuration.selectedAgent?.allowedToolNames()
        let systemPrompt = resolvedSystemPrompt(
            providedSystemPrompt: params["systemPrompt"] as? String,
            cwd: cwd,
            allowedToolNames: allowedToolNames
        )
        let thinkingSelection = Self.thinkingSelection(from: params["thinkingSelection"])
        let preserveThinking = (params["preserveThinking"] as? Bool) ?? false
        let configuration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: self.configuration.effectiveModelID,
            bearerToken: self.configuration.bearerToken,
            workingDirectory: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: runtimeHistory(from: params["history"]),
            allowedToolNames: allowedToolNames,
            maxToolRounds: self.configuration.maxToolRounds,
            maxOutputTokens: self.configuration.maxOutputTokens,
            verboseLogging: self.configuration.verboseLogging,
            appMode: self.configuration.appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
        sessions[sessionID] = SessionState(
            id: sessionID,
            cwd: cwd,
            allowedToolNames: allowedToolNames,
            configuration: configuration,
            activePromptTask: nil
        )
        try await sessionRunner.createSession(configuration: configuration)

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: [
                "sessionId": sessionID,
                "modes": [
                    "availableModes": [
                        [
                            "id": "default",
                            "name": "Default",
                            "description": "Use the configured mlx-coder agent runtime."
                        ],
                        [
                            "id": "chat",
                            "name": "Chat",
                            "description": "Alias for the default mlx-coder agent runtime."
                        ]
                    ],
                    "currentModeId": "default"
                ],
                "configOptions": []
            ])
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: cwd).lastPathComponent
        )
    }

    public func setMode(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = Self.sessionID(from: params) else {
            throw ACPError(code: -32602, message: "Missing sessionId.")
        }
        guard sessions[sessionID] != nil else {
            throw ACPError(code: -32002, message: "Unknown session: \(sessionID)")
        }
        let modeID = ((params["modeId"] as? String) ?? (params["mode_id"] as? String) ?? "default")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModeID = modeID.isEmpty ? "default" : modeID
        guard normalizedModeID == "default" || normalizedModeID == "chat" else {
            throw ACPError(code: -32602, message: "Unsupported mode: \(normalizedModeID)")
        }
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: [
                "sessionId": sessionID,
                "modeId": normalizedModeID
            ])
        )
    }

    private static func sessionID(from params: [String: Any]) -> String? {
        for key in ["sessionId", "session_id"] {
            if let value = (params[key] as? String)?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    private func defaultSessionConfiguration(
        sessionID: String
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: configuration.effectiveModelID,
            bearerToken: configuration.bearerToken,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: nil,
            preserveThinking: false
        )
    }

}
