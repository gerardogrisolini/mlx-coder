//
//  MLXServerHTTPPayloads.swift
//  mlx-server
//

import Foundation
import MLXLMCommon
import MLXServerCore

extension JSONEncoder {
    static var mlxServer: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

extension JSONValue {
    var sendableValue: any Sendable {
        switch self {
        case .null:
            self
        case .bool(let value):
            value
        case .int(let value):
            value
        case .double(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(\.sendableValue)
        case .object(let values):
            values.mapValues(\.sendableValue)
        }
    }
}

enum MLXServerHTTPToolArguments {
    static func object(from value: JSONValue?) -> [String: any Sendable] {
        guard let value,
              case .object(let object) = value else {
            return [:]
        }
        return object.mapValues(\.sendableValue)
    }

    static func object(from json: String?) -> [String: any Sendable] {
        guard let json,
              let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .object(object) = value else {
            return [:]
        }
        return object.mapValues(\.sendableValue)
    }

}

struct FlexibleMessageContent: Decodable, Sendable {
    var text: String
    var thinkingText: String
    var imageURLs: [URL]
    var videoURLs: [URL]
    var toolResults: [MLXServerChatMessage]
    var toolUses: [MLXServerChatToolCall]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            thinkingText = ""
            imageURLs = []
            videoURLs = []
            toolResults = []
            toolUses = []
            return
        }

        let parts: [ContentPart]
        if let decodedParts = try? container.decode([ContentPart].self) {
            parts = decodedParts
        } else {
            parts = [try container.decode(ContentPart.self)]
        }
        text = parts.compactMap(\.resolvedText).joined(separator: "\n")
        thinkingText = parts.compactMap(\.resolvedThinking).joined(separator: "\n")
        imageURLs = parts.compactMap(\.resolvedImageURL)
        videoURLs = parts.compactMap(\.resolvedVideoURL)
        toolResults = parts.compactMap(\.resolvedToolResult)
        toolUses = parts.compactMap(\.resolvedToolUse)
    }

    var anthropicSystemText: String {
        text
            .components(separatedBy: "\n")
            .filter { line in
                !line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .hasPrefix("x-anthropic-billing-header:")
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ContentPart: Decodable, Sendable {
    var type: String?
    var id: String?
    var name: String?
    var text: String?
    var thinking: String?
    var content: FlexibleNestedTextContent?
    var input: JSONValue?
    var imageURL: FlexibleURLValue?
    var videoURL: FlexibleURLValue?
    var source: AnthropicMediaSource?
    var toolUseID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case id
        case name
        case text
        case thinking
        case content
        case input
        case imageURL = "image_url"
        case videoURL = "video_url"
        case source
        case toolUseID = "tool_use_id"
    }

    var resolvedText: String? {
        switch type {
        case "thinking", "tool_result", "tool_use":
            nil
        case "text", "input_text", nil:
            text
        default:
            text
        }
    }

    var resolvedThinking: String? {
        guard type == "thinking" else {
            return nil
        }
        return thinking ?? text
    }

    var resolvedToolUse: MLXServerChatToolCall? {
        guard type == "tool_use" else {
            return nil
        }
        return MLXServerChatToolCall(
            id: id,
            name: name ?? "",
            arguments: MLXServerHTTPToolArguments.object(from: input)
        )
    }

    var resolvedImageURL: URL? {
        switch type {
        case "image", "image_url", "input_image":
            imageURL?.url ?? source?.url
        default:
            imageURL?.url
        }
    }

    var resolvedVideoURL: URL? {
        switch type {
        case "video", "video_url", "input_video":
            videoURL?.url ?? source?.url
        default:
            videoURL?.url
        }
    }

    var resolvedToolResult: MLXServerChatMessage? {
        guard type == "tool_result" else {
            return nil
        }

        let body = content?.text ?? text ?? ""
        return .tool(body, toolCallID: toolUseID)
    }
}

struct FlexibleNestedTextContent: Decodable, Sendable {
    var text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            return
        }

        let parts: [NestedTextPart]
        if let decodedParts = try? container.decode([NestedTextPart].self) {
            parts = decodedParts
        } else {
            parts = [try container.decode(NestedTextPart.self)]
        }
        text = parts.compactMap(\.text).joined(separator: "\n")
    }

    private struct NestedTextPart: Decodable, Sendable {
        var type: String?
        var text: String?
    }
}

struct FlexibleURLValue: Decodable, Sendable {
    var url: URL?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            url = URL(string: string)
            return
        }

        let object = try container.decode(URLObject.self)
        url = object.url.flatMap(URL.init(string:))
    }

    private struct URLObject: Decodable {
        var url: String?
    }
}

struct AnthropicMediaSource: Decodable, Sendable {
    var type: String?
    var url: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
    }
}
