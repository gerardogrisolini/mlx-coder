//
//  Split from RemoteGenerationClient.swift
//  MLXCoder
//

import Foundation

extension RemoteGenerationClient {
    public static func systemPrompt(
        cwd: String,
        allowedToolNames: Set<String>?
    ) -> String {
        AgentStandaloneSystemPrompt.prompt(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled(allowedToolNames)
        )
    }

    public static func initialMessages(
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>?
    ) -> [[String: Any]] {
        let seededMessages = history.compactMap(remoteMessage(from:))
        if let firstRole = seededMessages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            return seededMessages
        }

        let prompt = systemPrompt?.nilIfBlank
            ?? Self.systemPrompt(
                cwd: cwd,
                allowedToolNames: allowedToolNames
            )
        return [
            [
                "role": "system",
                "content": prompt
            ]
        ] + seededMessages
    }

    public static func replacingSystemPrompt(
        in messages: [[String: Any]],
        cwd: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?
    ) -> [[String: Any]] {
        let prompt = systemPrompt?.nilIfBlank
            ?? Self.systemPrompt(
                cwd: cwd,
                allowedToolNames: allowedToolNames
            )
        var updatedMessages = messages
        if let firstRole = updatedMessages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            updatedMessages[0] = [
                "role": "system",
                "content": prompt
            ]
        } else {
            updatedMessages.insert(
                [
                    "role": "system",
                    "content": prompt
                ],
                at: 0
            )
        }
        return updatedMessages
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    public static func remoteMessage(from message: AgentRuntimeMessage) -> [String: Any]? {
        var payload = remoteMessage(
            role: message.role.rawValue,
            content: message.content,
            attachments: message.attachments
        )
        if message.role == .assistant, !message.toolCalls.isEmpty {
            payload["tool_calls"] = message.toolCalls.map { toolCall in
                [
                    "id": toolCall.id ?? "call_\(UUID().uuidString.lowercased())",
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ] as [String: Any]
            }
        }
        if message.role == .tool {
            if let toolCallID = message.toolCallID {
                payload["tool_call_id"] = toolCallID
            }
            if let toolName = message.toolName {
                payload["name"] = toolName
            }
        }
        guard responseMessagePayloadHasContent(payload) else {
            return nil
        }
        return payload
    }

    public static func remoteMessage(
        role: String,
        content: String,
        attachments: [AgentRuntimeAttachment]
    ) -> [String: Any] {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedContent = promptContent(
            content,
            role: normalizedRole,
            attachments: attachments
        )
        return [
            "role": normalizedRole.isEmpty ? "user" : normalizedRole,
            "content": chatCompletionsContentPayload(
                content: normalizedContent,
                attachments: attachments
            )
        ]
    }

    public static func promptContent(
        _ content: String,
        role: String,
        attachments: [AgentRuntimeAttachment]
    ) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user", text.isEmpty, !attachments.isEmpty else {
            return text
        }
        return "Analyze the attached media."
    }

    public static func responseMessagePayloadHasContent(_ message: [String: Any]) -> Bool {
        if let content = contentString(from: message["content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return true
        }

        return !chatCompletionsImageContentItems(from: message["content"]).isEmpty
            || !((message["tool_calls"] as? [[String: Any]])?.isEmpty ?? true)
    }

    public static func chatCompletionsContentPayload(
        content: String,
        attachments: [AgentRuntimeAttachment]
    ) -> Any {
        let imageItems = imageDataURLs(from: attachments).map { dataURL in
            [
                "type": "image_url",
                "image_url": [
                    "url": dataURL
                ]
            ]
        }
        guard !imageItems.isEmpty else {
            return content
        }

        var items: [[String: Any]] = []
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append([
                "type": "text",
                "text": content
            ])
        }
        items.append(contentsOf: imageItems)
        return items
    }

    public static func responsesInputPayload(
        from messages: [[String: Any]]
    ) -> (instructions: String?, input: [Any]) {
        var instructions: [String] = []
        var input: [Any] = []

        for message in messages {
            let role = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if role == "system" {
                if let content = contentString(from: message["content"]),
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    instructions.append(content)
                }
                continue
            }

            if role != "tool" {
                let contentItems = responsesContentItems(from: message["content"])
                if !contentItems.isEmpty {
                    input.append(
                        responsesMessagePayload(
                            role: role.isEmpty ? "user" : role,
                            contentItems: contentItems
                        )
                    )
                }
            }

            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                input.append(contentsOf: toolCalls.compactMap(responseFunctionCallPayload(from:)))
            }

            if role == "tool",
               let callID = stringValue(message["tool_call_id"])?.nilIfBlank,
               let output = contentString(from: message["content"]) {
                input.append(
                    responseFunctionCallOutputPayload(
                        callID: callID,
                        output: output
                    )
                )
            }
        }

        let resolvedInstructions = instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (
            resolvedInstructions.isEmpty ? nil : resolvedInstructions,
            input
        )
    }

    public static func responsesMessagePayload(
        role: String,
        contentItems: [[String: Any]]
    ) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": contentItems
        ]
    }

    public static func responsesContentItems(from value: Any?) -> [[String: Any]] {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return []
            }
            return [
                [
                    "type": "input_text",
                    "text": trimmed
                ]
            ]
        }

        guard let items = value as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            let type = stringValue(item["type"])?.lowercased()
            switch type {
            case "input_text":
                guard let text = stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "input_text",
                    "text": text
                ]
            case "text":
                guard let text = stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "input_text",
                    "text": text
                ]
            case "input_image":
                guard let imageURL = stringValue(item["image_url"])?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "input_image",
                    "image_url": imageURL
                ]
            case "image_url":
                guard let imageURL = chatCompletionsImageURL(from: item)?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "input_image",
                    "image_url": imageURL
                ]
            default:
                return nil
            }
        }
    }

    public static func responseFunctionCallPayload(
        from toolCall: [String: Any]
    ) -> [String: Any]? {
        guard let function = toolCall["function"] as? [String: Any],
              let name = stringValue(function["name"])?.nilIfBlank else {
            return nil
        }
        return [
            "type": "function_call",
            "call_id": stringValue(toolCall["id"]) ?? "call_\(UUID().uuidString.lowercased())",
            "name": name,
            "arguments": stringValue(function["arguments"]) ?? "{}"
        ]
    }

    public static func responseFunctionCallOutputPayload(
        callID: String,
        output: String
    ) -> [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": output
        ]
    }

    public static func contentString(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let items = value as? [[String: Any]] {
            let text = items.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                return item["content"] as? String
            }
            .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    public static func chatCompletionsImageContentItems(from value: Any?) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else {
            return []
        }
        return items.filter { item in
            stringValue(item["type"])?.lowercased() == "image_url"
                && chatCompletionsImageURL(from: item)?.nilIfBlank != nil
        }
    }

    public static func chatCompletionsImageURL(from item: [String: Any]) -> String? {
        if let imageURL = item["image_url"] as? String {
            return imageURL
        }
        if let imageURL = item["image_url"] as? [String: Any] {
            return stringValue(imageURL["url"])
        }
        return nil
    }

    public static func imageDataURLs(from attachments: [AgentRuntimeAttachment]) -> [String] {
        attachments.compactMap { attachment in
            guard attachment.kind == .image,
                  let data = attachmentData(for: attachment) else {
                return nil
            }
            return "data:\(mimeType(for: attachment));base64,\(data.base64EncodedString())"
        }
    }

    public static func attachmentData(for attachment: AgentRuntimeAttachment) -> Data? {
        if let data = attachment.data {
            return data
        }
        guard let fileURL = attachment.fileURL else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    public static func mimeType(for attachment: AgentRuntimeAttachment) -> String {
        if let contentType = attachment.contentType,
           contentType.contains("/") {
            return contentType
        }

        let pathExtension = URL(fileURLWithPath: attachment.originalFilename)
            .pathExtension
            .lowercased()
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        default:
            return "image/png"
        }
    }

    public static func isResponseToolCallItem(_ item: [String: Any]) -> Bool {
        let type = stringValue(item["type"])?.lowercased()
        return type == "function_call" || type == "custom_tool_call"
    }

    public static func responseOutputText(from item: [String: Any]) -> String? {
        guard stringValue(item["type"])?.lowercased() == "message" else {
            return nil
        }
        return contentString(from: item["content"])
    }
}
