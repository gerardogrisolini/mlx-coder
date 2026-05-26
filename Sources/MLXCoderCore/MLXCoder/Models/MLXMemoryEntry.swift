//
//  MLXMemoryEntry.swift
//  SwiftMLX
//
//  Created by Gerardo Grisolini on 06/04/26.
//

import Foundation

public nonisolated enum MLXMemoryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case global
    case project
}

public nonisolated struct MLXMemoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var scope: MLXMemoryScope
    public var content: String
    public var isArchived: Bool

    public init(
        content: String,
        scope: MLXMemoryScope = .project,
        id: UUID = UUID(),
        isArchived: Bool = false
    ) {
        self.id = id
        self.scope = scope
        self.content = Self.normalizedContent(content)
        self.isArchived = isArchived
    }

    public var title: String {
        let firstLine = content
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Memory"
        guard firstLine.count > 80 else {
            return firstLine.isEmpty ? "Memory" : firstLine
        }
        return String(firstLine.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    public static func normalizedContent(_ content: String) -> String {
        content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
    }
}
