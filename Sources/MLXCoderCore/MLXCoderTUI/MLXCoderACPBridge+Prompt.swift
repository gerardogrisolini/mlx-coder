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
    public func prompt(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = params["sessionId"] as? String,
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
            throw ACPError.invalidParams("A prompt is already running for this session.")
        }

        let promptBlocks = promptBlocks(from: params)
        let promptText = PromptContentFormatter.renderPromptText(from: promptBlocks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty else {
            throw ACPError.invalidParams("session/prompt requires non-empty prompt text.")
        }

        await sendUserMessageChunk(sessionID: sessionID, text: promptText)
        await sendSessionInfoUpdate(sessionID: sessionID, title: promptTitle(from: promptText))

        let writer = self.writer
        let appMode = configuration.appMode
        let updateBuffer = appMode ? ACPPromptUpdateBuffer() : nil
        let sessionRunner = self.sessionRunner

        @Sendable func sendPromptUpdate(_ update: JSONValue) async {
            if let updateBuffer {
                for bufferedUpdate in updateBuffer.consume(update) {
                    await writer.sendSessionUpdate(
                        sessionID: sessionID,
                        update: bufferedUpdate
                    )
                }
            } else {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: update
                )
            }
        }

        func flushPromptUpdates() async {
            guard let updateBuffer else {
                return
            }
            for update in updateBuffer.flushAll() {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: update
                )
            }
        }

        let promptConfiguration = session.configuration
        let activePromptTask = Task {
            let response = try await sessionRunner.sendPrompt(
                configuration: promptConfiguration,
                prompt: promptText,
                attachments: [],
                onEvent: { event in
                    switch event {
                    case let .status(message):
                        if !appMode {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": message
                                ]
                            ]))
                        }
                    case let .diagnostic(message):
                        if Self.isMetricsDiagnostic(message) {
                            break
                        }
                        if !appMode || !Self.isAppSuppressedDiagnostic(message) {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": message
                                ]
                            ]))
                        }
                    case let .thought(message):
                        await sendPromptUpdate(JSONValue.acpValue(from: [
                            "sessionUpdate": "agent_thought_chunk",
                            "content": [
                                "type": "text",
                                "text": message
                            ]
                        ]))
                    case let .modelLoaded(modelID):
                        if !appMode {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": "Loaded model: \(modelID)"
                                ]
                            ]))
                        }
                    case let .metrics(metrics):
                        await sendPromptUpdate(JSONValue.acpValue(from: Self.metricsUpdate(for: metrics)))
                    case let .contextWindow(status):
                        await sendPromptUpdate(JSONValue.acpValue(from: Self.contextWindowUpdate(for: status)))
                    case let .content(content):
                        await sendPromptUpdate(JSONValue.acpValue(from: [
                            "sessionUpdate": "agent_message_chunk",
                            "content": [
                                "type": "text",
                                "text": content
                            ]
                        ]))
                    case let .toolCallStarted(toolCall):
                        await sendPromptUpdate(JSONValue.acpValue(from: Self.toolCallCreateUpdate(for: toolCall)))
                        await sendPromptUpdate(JSONValue.acpValue(from: Self.toolCallProgressUpdate(for: toolCall)))
                    case let .toolCallCompleted(toolCall, result):
                        await sendPromptUpdate(
                            JSONValue.acpValue(from: Self.toolCallCompletionUpdate(
                                for: toolCall,
                                result: result
                            ))
                        )
                    }
                }
            )
            return PromptCompletion(
                text: response.text,
                stopReason: response.stopReason
            )
        }

        session.activePromptTask = activePromptTask
        sessions[sessionID] = session

        do {
            let completion = try await activePromptTask.value
            await flushPromptUpdates()
            var refreshedSession = sessions[sessionID] ?? session
            refreshedSession.activePromptTask = nil
            sessions[sessionID] = refreshedSession

            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: ["stopReason": completion.stopReason])
            )
        } catch is CancellationError {
            await flushPromptUpdates()
            sessions[sessionID]?.activePromptTask = nil
            await writer.sendResultIfRequest(
                id: id,
                result: JSONValue.acpValue(from: ["stopReason": "cancelled"])
            )
        } catch {
            await flushPromptUpdates()
            sessions[sessionID]?.activePromptTask = nil
            throw error
        }
    }

    public func cancel(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = params["sessionId"] as? String,
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        session.activePromptTask?.cancel()
        session.activePromptTask = nil
        sessions[sessionID] = session
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    public func close(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = params["sessionId"] as? String else {
            throw ACPError.invalidParams("session/close requires params.sessionId.")
        }
        sessions[sessionID]?.activePromptTask?.cancel()
        sessions.removeValue(forKey: sessionID)
        await sessionRunner.closeSession(id: sessionID)
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    public func promptBlocks(from params: [String: Any]) -> [Any] {
        if let prompt = params["prompt"] as? [Any] {
            return prompt
        }
        if let content = params["content"] as? [Any] {
            return content
        }
        if let prompt = params["prompt"] as? String {
            return [["type": "text", "text": prompt]]
        }
        if let content = params["content"] as? String {
            return [["type": "text", "text": content]]
        }
        return []
    }
}
