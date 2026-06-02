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
    public func prompt(id: JSONValue?, params: [String: Any]) async throws {
        guard let sessionID = params["sessionId"] as? String,
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard session.activePromptTask == nil else {
            throw ACPError.invalidParams("A prompt is already running for this session.")
        }

        let promptBlocks = promptBlocks(from: params)
        let rawPromptText = PromptContentFormatter.renderPromptText(from: promptBlocks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = Self.promptAttachments(
            from: promptBlocks,
            renderedPromptText: rawPromptText,
            cwd: session.cwd
        )
        let promptText = Self.promptTextRemovingAionFilesMarker(rawPromptText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !promptText.isEmpty || !attachments.isEmpty else {
            throw ACPError.invalidParams("session/prompt requires prompt text or attachments.")
        }

        let visiblePromptText = promptText.isEmpty ? "Analyze the attached media." : promptText
        await sendUserMessageChunk(sessionID: sessionID, text: visiblePromptText)
        await sendSessionInfoUpdate(sessionID: sessionID, title: promptTitle(from: visiblePromptText))

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
                attachments: attachments,
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
                    case let .modelLoadedDetails(details):
                        if !appMode {
                            await sendPromptUpdate(JSONValue.acpValue(from: [
                                "sessionUpdate": "agent_thought_chunk",
                                "content": [
                                    "type": "text",
                                    "text": "Loaded model: \(details.modelID)"
                                ]
                            ]))
                        }
                    case .metrics:
                        break
                    case let .contextWindow(status):
                        if let update = Self.usageUpdate(for: status) {
                            await sendPromptUpdate(JSONValue.acpValue(from: update))
                        }
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
                    case .sessionSnapshot,
                         .turnEnded:
                        break
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
            return [
                [
                    "type": "text",
                    "text": prompt
                ] as [String: Any]
            ]
        }
        if let content = params["content"] as? String {
            return [
                [
                    "type": "text",
                    "text": content
                ] as [String: Any]
            ]
        }
        return []
    }

    public static func promptAttachments(
        from blocks: [Any],
        renderedPromptText: String,
        cwd: String
    ) -> [AgentRuntimeAttachment] {
        var attachments: [AgentRuntimeAttachment] = []
        var seenKeys = Set<String>()

        func append(_ attachment: AgentRuntimeAttachment?) {
            guard let attachment else {
                return
            }
            let key = attachment.fileURL?.standardizedFileURL.path
                ?? "\(attachment.originalFilename):\(attachment.data?.count ?? 0)"
            guard seenKeys.insert(key).inserted else {
                return
            }
            attachments.append(attachment)
        }

        for block in blocks {
            append(promptAttachment(from: block, cwd: cwd))
        }
        for fileURL in aionFileAttachmentURLs(from: renderedPromptText, cwd: cwd) {
            append(try? AgentRuntimeAttachmentStore.importFile(from: fileURL).runtimeAttachment)
        }
        return attachments
    }

    public static func promptTextRemovingAionFilesMarker(_ text: String) -> String {
        var retainedLines: [String] = []
        var isSkippingAionFiles = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[[AION_FILES]]" {
                isSkippingAionFiles = true
                continue
            }
            if isSkippingAionFiles {
                if trimmed.isEmpty {
                    isSkippingAionFiles = false
                }
                continue
            }
            retainedLines.append(String(line))
        }
        return retainedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func promptAttachment(from block: Any, cwd: String) -> AgentRuntimeAttachment? {
        guard let object = block as? [String: Any] else {
            return nil
        }
        let type = stringValue(object["type"])?.lowercased() ?? "text"

        switch type {
        case "image", "input_image":
            return imageAttachment(from: object, cwd: cwd)
        case "image_url":
            return imageURLAttachment(from: object["image_url"], cwd: cwd)
        case "resource":
            guard let resource = object["resource"] as? [String: Any] else {
                return nil
            }
            return imageAttachment(from: resource, cwd: cwd)
        default:
            if let imageURL = object["image_url"] {
                return imageURLAttachment(from: imageURL, cwd: cwd)
            }
            return nil
        }
    }

    private static func imageAttachment(from object: [String: Any], cwd: String) -> AgentRuntimeAttachment? {
        let contentType = firstString(
            in: object,
            keys: ["mimeType", "mime_type", "mediaType", "media_type", "contentType", "content_type"]
        )
        let originalFilename = firstString(
            in: object,
            keys: ["filename", "fileName", "name", "title"]
        )
        if let data = firstBase64Data(in: object) {
            return AgentRuntimeAttachment(
                kind: .image,
                data: data,
                contentType: contentType,
                originalFilename: originalFilename
                    ?? embeddedAttachmentFilename(contentType: contentType)
            )
        }

        if let uri = firstString(in: object, keys: ["uri", "url", "path", "image_url"]),
           let attachment = imageURLAttachment(from: uri, cwd: cwd, contentType: contentType) {
            return attachment
        }
        return nil
    }

    private static func imageURLAttachment(
        from value: Any?,
        cwd: String,
        contentType: String? = nil
    ) -> AgentRuntimeAttachment? {
        let rawURL: String?
        if let string = value as? String {
            rawURL = string
        } else if let object = value as? [String: Any] {
            rawURL = firstString(in: object, keys: ["url", "uri", "path"])
        } else {
            rawURL = nil
        }

        guard let rawURL = rawURL?.nilIfBlank else {
            return nil
        }
        if let (mimeType, data) = imageDataURL(rawURL) {
            return AgentRuntimeAttachment(
                kind: .image,
                data: data,
                contentType: contentType ?? mimeType,
                originalFilename: embeddedAttachmentFilename(contentType: contentType ?? mimeType)
            )
        }
        guard let fileURL = fileURL(from: rawURL, cwd: cwd) else {
            return nil
        }
        return try? AgentRuntimeAttachmentStore.importFile(from: fileURL).runtimeAttachment
    }

    private static func aionFileAttachmentURLs(from text: String, cwd: String) -> [URL] {
        var urls: [URL] = []
        var isReadingFiles = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "[[AION_FILES]]" {
                isReadingFiles = true
                continue
            }
            guard isReadingFiles else {
                continue
            }
            if trimmed.isEmpty {
                isReadingFiles = false
                continue
            }
            if let url = fileURL(from: trimmed, cwd: cwd) {
                urls.append(url)
            }
        }
        return urls
    }

    private static func firstBase64Data(in object: [String: Any]) -> Data? {
        for key in ["data", "blob", "base64", "bytes"] {
            guard let value = stringValue(object[key])?.nilIfBlank else {
                continue
            }
            if let (_, data) = imageDataURL(value) {
                return data
            }
            if let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) {
                return data
            }
        }
        return nil
    }

    private static func imageDataURL(_ value: String) -> (mimeType: String?, data: Data)? {
        guard value.lowercased().hasPrefix("data:"),
              let separatorRange = value.range(of: ";base64,") else {
            return nil
        }
        let mimeType = String(value[value.index(value.startIndex, offsetBy: 5)..<separatorRange.lowerBound])
            .nilIfBlank
        let base64 = String(value[separatorRange.upperBound...])
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return (mimeType, data)
    }

    private static func fileURL(from value: String, cwd: String) -> URL? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        guard !value.contains("://") else {
            return nil
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(value)
            .standardizedFileURL
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key])?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        return nil
    }

    private static func embeddedAttachmentFilename(contentType: String?) -> String {
        let fileExtension = AgentRuntimeAttachmentStore.preferredFilenameExtension(
            originalFilename: "",
            contentType: contentType
        )
        return fileExtension.isEmpty ? "image" : "image.\(fileExtension)"
    }
}
