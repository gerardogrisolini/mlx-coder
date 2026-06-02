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
                "loadSession": true,
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
                    "close": [:],
                    "resume": [:]
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
        let preloadConfiguration = defaultSessionConfiguration(sessionID: "preload")
            .withModelID(Self.modelID(from: params) ?? configuration.effectiveModelID)
        let modelID = try await sessionRunner.preloadModel(
            configuration: preloadConfiguration
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
        let modelID = Self.modelID(from: params)
            ?? configuration.effectiveModelID

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
            modelID: modelID,
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
        sessions[sessionID] = sessionState(configuration: configuration)
        try await sessionRunner.createSession(configuration: configuration)
        await persistSessionSnapshotIfAvailable(sessionID: sessionID)

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: cwd).lastPathComponent
        )
    }

    public func loadSession(id: JSONValue?, params: [String: Any]) async throws {
        try await restoreSession(id: id, params: params, replayHistory: true)
    }

    public func resumeSession(id: JSONValue?, params: [String: Any]) async throws {
        try await restoreSession(id: id, params: params, replayHistory: false)
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

    public func setConfigOption(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = Self.sessionID(from: params),
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
            throw ACPError.invalidParams("Cannot change session options while a prompt is running.")
        }

        guard let configID = Self.configOptionID(from: params) else {
            throw ACPError.invalidParams("Missing configId.")
        }
        guard let value = Self.configOptionValue(from: params) else {
            throw ACPError.invalidParams("Missing config option value.")
        }
        guard configID == "model" else {
            throw ACPError.invalidParams("Unsupported config option: \(configID)")
        }
        let availableModels = modelConfigOptions()
        guard availableModels.contains(where: { option in
            (option["value"] as? String) == value
        }) else {
            throw ACPError.invalidParams("Unsupported model: \(value)")
        }

        let updatedConfiguration = session.configuration.withModelID(value)
        sessions[sessionID] = sessionState(configuration: updatedConfiguration)
        try await sessionRunner.createSession(configuration: updatedConfiguration)
        await persistSessionSnapshotIfAvailable(sessionID: sessionID)
        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: [
                "configOptions": configOptions(for: updatedConfiguration.modelID)
            ])
        )
    }

    public func setModel(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = Self.sessionID(from: params),
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
            throw ACPError.invalidParams("Cannot change session model while a prompt is running.")
        }
        guard let modelID = Self.modelID(from: params) else {
            throw ACPError.invalidParams("Missing modelId.")
        }
        guard modelConfigOptions().contains(where: { option in
            (option["value"] as? String) == modelID
        }) else {
            throw ACPError.invalidParams("Unsupported model: \(modelID)")
        }

        let updatedConfiguration = session.configuration.withModelID(modelID)
        sessions[sessionID] = sessionState(configuration: updatedConfiguration)
        try await sessionRunner.createSession(configuration: updatedConfiguration)
        await persistSessionSnapshotIfAvailable(sessionID: sessionID)
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    public func restoreSession(
        id: JSONValue?,
        params: [String: Any],
        replayHistory: Bool
    ) async throws {
        guard let sessionID = Self.sessionID(from: params) else {
            throw ACPError.invalidParams("ACP session restore requires params.sessionId.")
        }
        if let session = sessions[sessionID] {
            if replayHistory,
               let snapshot = await sessionRunner.snapshotSession(id: sessionID) {
                await replaySessionHistory(snapshot)
            }
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
            )
            await sendSessionInfoUpdate(
                sessionID: sessionID,
                title: URL(fileURLWithPath: session.cwd).lastPathComponent
            )
            return
        }

        let rawCwd = Self.workingDirectory(from: params)
            ?? configuration.workingDirectory.path
        let workingDirectory = AgentConfiguration.resolvedWorkingDirectory(rawValue: rawCwd)
        guard let snapshot = try MLXCoderACPSessionStore.load(
            sessionID: sessionID,
            workingDirectory: workingDirectory
        ) else {
            throw ACPError(code: -32002, message: "Unknown session: \(sessionID)")
        }

        let configuration = sessionConfiguration(from: snapshot)
        sessions[sessionID] = sessionState(configuration: configuration)
        try await sessionRunner.createSession(configuration: configuration)
        if replayHistory {
            await replaySessionHistory(snapshot)
        }

        await writer.sendResultIfRequest(
            id: id,
            result: JSONValue.acpValue(from: sessionLifecycleResult(sessionID: sessionID))
        )
        await sendSessionInfoUpdate(
            sessionID: sessionID,
            title: URL(fileURLWithPath: snapshot.workingDirectoryPath).lastPathComponent
        )
    }

    public static func sessionID(from params: [String: Any]) -> String? {
        for key in ["sessionId", "session_id", "id"] {
            if let value = (params[key] as? String)?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    public static func configOptionID(from params: [String: Any]) -> String? {
        (params["configId"] as? String)?.nilIfBlank
            ?? (params["configID"] as? String)?.nilIfBlank
            ?? (params["config_id"] as? String)?.nilIfBlank
            ?? (params["id"] as? String)?.nilIfBlank
    }

    public static func configOptionValue(from params: [String: Any]) -> String? {
        if let value = (params["value"] as? String)?.nilIfBlank
            ?? (params["currentValue"] as? String)?.nilIfBlank
            ?? (params["current_value"] as? String)?.nilIfBlank {
            return value
        }
        if let option = params["option"] as? [String: Any] {
            return (option["value"] as? String)?.nilIfBlank
                ?? (option["id"] as? String)?.nilIfBlank
        }
        return nil
    }

    public static func modelID(from params: [String: Any]) -> String? {
        if let value = (params["modelId"] as? String)?.nilIfBlank
            ?? (params["modelID"] as? String)?.nilIfBlank
            ?? (params["model_id"] as? String)?.nilIfBlank
            ?? (params["currentModelId"] as? String)?.nilIfBlank
            ?? (params["current_model_id"] as? String)?.nilIfBlank
            ?? (params["model"] as? String)?.nilIfBlank {
            return value
        }
        if let config = params["config"] as? [String: Any],
           let value = (config["model"] as? String)?.nilIfBlank
               ?? (config["modelId"] as? String)?.nilIfBlank
               ?? (config["model_id"] as? String)?.nilIfBlank {
            return value
        }
        if let models = params["models"] as? [String: Any] {
            return (models["currentModelId"] as? String)?.nilIfBlank
                ?? (models["current_model_id"] as? String)?.nilIfBlank
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

    public func sessionLifecycleResult(sessionID: String) -> [String: Any] {
        let modelID = sessions[sessionID]?.configuration.modelID
            ?? configuration.effectiveModelID
        return [
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
            "configOptions": configOptions(for: modelID),
            "models": modelState(for: modelID)
        ]
    }

    public func configOptions(for modelID: String?) -> [[String: Any]] {
        let modelOptions = modelConfigOptions()
        guard !modelOptions.isEmpty else {
            return []
        }
        let selectedModelID = modelID?.nilIfBlank
            ?? configuration.effectiveModelID?.nilIfBlank
            ?? (modelOptions.first?["value"] as? String)
            ?? ""
        return [
            [
                "id": "model",
                "name": "Model",
                "category": "model",
                "type": "select",
                "currentValue": selectedModelID,
                "options": modelOptions
            ]
        ]
    }

    public func modelConfigOptions() -> [[String: Any]] {
        let models = configuration.hostedModels ?? AgentSettingsStore.availableModels()
        return models.map { model in
            [
                "value": model.id,
                "name": model.displayTitle,
                "description": model.modelID
            ]
        }
    }

    public func modelState(for modelID: String?) -> [String: Any] {
        let modelOptions = modelConfigOptions()
        let selectedModelID = modelID?.nilIfBlank
            ?? configuration.effectiveModelID?.nilIfBlank
            ?? (modelOptions.first?["value"] as? String)
            ?? ""
        return [
            "currentModelId": selectedModelID,
            "availableModels": modelOptions.map { option in
                [
                    "modelId": option["value"] as? String ?? "",
                    "name": option["name"] as? String ?? "",
                    "description": option["description"] as? String ?? ""
                ]
            }
        ]
    }

    public func sessionState(
        configuration: AgentCoreSessionConfiguration,
        activePromptTask: Task<PromptCompletion, Error>? = nil
    ) -> SessionState {
        SessionState(
            id: configuration.sessionID,
            cwd: configuration.workingDirectory.path,
            allowedToolNames: configuration.allowedToolNames,
            configuration: configuration,
            activePromptTask: activePromptTask
        )
    }

    public func sessionConfiguration(
        from snapshot: AgentRuntimeSessionSnapshot
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: snapshot.sessionID,
            modelID: snapshot.modelID ?? configuration.effectiveModelID,
            bearerToken: configuration.bearerToken,
            workingDirectory: snapshot.workingDirectoryPath,
            systemPrompt: snapshot.systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: snapshot.history,
            allowedToolNames: snapshot.allowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
    }

    public func persistSessionSnapshotIfAvailable(sessionID: String) async {
        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID) else {
            return
        }
        do {
            try MLXCoderACPSessionStore.save(snapshot)
        } catch {
            SwiftMLXLogger.warning(
                .viewModelRuntime,
                "failed to persist ACP session id=\(sessionID): \(error.localizedDescription)"
            )
        }
        guard let session = sessions[sessionID] else {
            return
        }
        sessions[sessionID] = sessionState(
            configuration: sessionConfiguration(from: snapshot),
            activePromptTask: session.activePromptTask
        )
    }

    public func replaySessionHistory(_ snapshot: AgentRuntimeSessionSnapshot) async {
        for message in snapshot.history {
            switch message.role {
            case .user:
                let text = replayText(for: message)
                guard let text else {
                    continue
                }
                await sendUserMessageChunk(sessionID: snapshot.sessionID, text: text)
            case .assistant:
                if let thought = message.reasoningContent?.nilIfBlank {
                    await writer.sendSessionUpdate(
                        sessionID: snapshot.sessionID,
                        update: JSONValue.acpValue(from: [
                            "sessionUpdate": "agent_thought_chunk",
                            "content": [
                                "type": "text",
                                "text": thought
                            ]
                        ])
                    )
                }
                guard let text = message.content.nilIfBlank else {
                    continue
                }
                await writer.sendSessionUpdate(
                    sessionID: snapshot.sessionID,
                    update: JSONValue.acpValue(from: [
                        "sessionUpdate": "agent_message_chunk",
                        "content": [
                            "type": "text",
                            "text": text
                        ]
                    ])
                )
            case .system, .tool:
                continue
            }
        }
    }

    private func replayText(for message: AgentRuntimeMessage) -> String? {
        if let content = message.content.nilIfBlank {
            return content
        }
        guard !message.attachments.isEmpty else {
            return nil
        }
        return "Analyze the attached media."
    }

}
