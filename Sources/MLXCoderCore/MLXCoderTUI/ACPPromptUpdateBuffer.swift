//
//  Generated split from MLXCoder.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public final class ACPPromptUpdateBuffer: @unchecked Sendable {
    private var pendingContent = ""
    private var latestUsageUpdate: JSONValue?
    private var lastContentFlushAt = Date()
    private var lastMetadataFlushAt = Date()

    public func consume(_ update: JSONValue) -> [JSONValue] {
        guard let object = update.mlxObjectValue else {
            return flushAll() + [update]
        }
        switch object["sessionUpdate"]?.acpStringValue {
        case "agent_message_chunk":
            guard let content = object["content"]?.mlxObjectValue,
                  let text = content["text"]?.acpStringValue,
                  !text.isEmpty else {
                return []
            }
            pendingContent += text
            return flushContentIfNeeded(force: false)

        case "usage_update":
            latestUsageUpdate = update
            return flushMetadataIfNeeded(force: false)

        default:
            return flushAll() + [update]
        }
    }

    public func flushAll() -> [JSONValue] {
        flushContentIfNeeded(force: true) + flushMetadataIfNeeded(force: true)
    }

    private func flushContentIfNeeded(force: Bool) -> [JSONValue] {
        guard !pendingContent.isEmpty else {
            return []
        }

        let now = Date()
        let shouldFlush =
            force
            || pendingContent.count >= 1536
            || now.timeIntervalSince(lastContentFlushAt) >= 0.45
        guard shouldFlush else {
            return []
        }

        let content = pendingContent
        pendingContent.removeAll(keepingCapacity: true)
        lastContentFlushAt = now
        return [
            .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object([
                    "type": .string("text"),
                    "text": .string(content)
                ])
            ])
        ]
    }

    private func flushMetadataIfNeeded(force: Bool) -> [JSONValue] {
        guard latestUsageUpdate != nil else {
            return []
        }

        let now = Date()
        let shouldFlush =
            force
            || now.timeIntervalSince(lastMetadataFlushAt) >= 2.0
        guard shouldFlush else {
            return []
        }

        let usageUpdate = latestUsageUpdate
        latestUsageUpdate = nil
        lastMetadataFlushAt = now

        var updates: [JSONValue] = []
        if let usageUpdate {
            updates.append(usageUpdate)
        }
        return updates
    }
}
