//
//  MLXMemoryService.swift
//  SwiftMLX
//
//  Created by Gerardo Grisolini on 06/04/26.
//

import Foundation

public final class MLXMemoryService: @unchecked Sendable {
    public static let filename = "MEMORY.md"
    public static let entriesDidChangeNotification = Notification.Name("MLXMemoryEntriesDidChange")

    private let fileManager: FileManager
    private let globalMemoryDirectoryURL: URL?

    public init(
        fileManager: FileManager = .default,
        globalMemoryDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.globalMemoryDirectoryURL = globalMemoryDirectoryURL
    }

    public static func notifyMemoryEntriesChanged() {
        NotificationCenter.default.post(name: entriesDidChangeNotification, object: nil)
    }

    public static func toolUsagePromptSection() -> String {
        return """
        Memory tools:
        Durable memory is stored in global and project MEMORY.md files, but its contents are not preloaded into this prompt.
        Use `memory.search` with a targeted query when remembered preferences, repo conventions, prior decisions, or durable warnings could help the current task.
        Use `memory.read` only when you need to inspect current notes; scope can be `global`, `project`, or `all`.
        Use `memory.write` only for stable facts worth keeping across turns. Use `scope: project` for repository-specific notes and `scope: global` for user-level preferences or reusable context.
        Use `memory.archive` when a note is stale, superseded, incorrect, or no longer useful.
        Prefer fresh evidence from files, tools, builds, tests, or current user messages when it conflicts with memory.
        """
    }

    public func readEntries(
        scope: MLXMemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        readEntries(
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext),
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func readEntries(
        scope: MLXMemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        readEntries(
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func readEntries(
        scope: MLXMemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        memoryDocuments(workspaceRootURL: workspaceRootURL)
            .filter { document in
                scope == nil || document.scope == scope
            }
            .flatMap(readEntries(from:))
            .filter { includeArchived || !$0.isArchived }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    public func searchEntries(
        query: String,
        scope: MLXMemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        searchEntries(
            query: query,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext),
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func searchEntries(
        query: String,
        scope: MLXMemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        searchEntries(
            query: query,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func searchEntries(
        query: String,
        scope: MLXMemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return readEntries(
                scope: scope,
                workspaceRootURL: workspaceRootURL,
                includeArchived: includeArchived,
                limit: limit
            )
        }

        return readEntries(
            scope: scope,
            workspaceRootURL: workspaceRootURL,
            includeArchived: includeArchived,
            limit: .max
        )
        .map { entry in
            (entry: entry, score: searchScore(entry: entry, terms: terms))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.entry.scope.rawValue < rhs.entry.scope.rawValue
        }
        .prefix(max(limit, 0))
        .map(\.entry)
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MLXMemoryScope,
        workspaceContext: XcodeWorkspaceContext?
    ) throws -> MLXMemoryEntry {
        try writeEntry(
            content: content,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext)
        )
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MLXMemoryScope,
        workingDirectory: URL?
    ) throws -> MLXMemoryEntry {
        try writeEntry(
            content: content,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL
        )
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        let normalizedContent = MLXMemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MLXMemoryServiceError.missingField("content")
        }

        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        var entries = readEntries(from: document)
        if let existingEntry = entries.first(where: {
            !$0.isArchived && $0.content.localizedCaseInsensitiveCompare(normalizedContent) == .orderedSame
        }) {
            return existingEntry
        }

        let entry = MLXMemoryEntry(
            content: normalizedContent,
            scope: scope
        )
        entries.insert(entry, at: 0)
        try writeEntries(entries, to: document)
        Self.notifyMemoryEntriesChanged()
        return entry
    }

    @discardableResult
    public func replaceEntry(
        id: UUID,
        content: String,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        let normalizedContent = MLXMemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MLXMemoryServiceError.missingField("content")
        }

        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        var entries = readEntries(from: document)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw MLXMemoryServiceError.entryNotFound(id.uuidString)
        }

        entries[index].content = normalizedContent
        try writeEntries(entries, to: document)
        Self.notifyMemoryEntriesChanged()
        return entries[index]
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MLXMemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?
    ) throws -> MLXMemoryEntry {
        try archiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext)
        )
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MLXMemoryScope?,
        workingDirectory: URL?
    ) throws -> MLXMemoryEntry {
        try archiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL
        )
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MLXMemoryScope?,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        guard let id = UUID(uuidString: rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MLXMemoryServiceError.invalidIdentifier(rawIdentifier)
        }

        let documents = memoryDocuments(workspaceRootURL: workspaceRootURL)
            .filter { scope == nil || $0.scope == scope }
        for document in documents {
            var entries = readEntries(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                continue
            }

            entries[index].isArchived = true
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
            return entries[index]
        }

        throw MLXMemoryServiceError.entryNotFound(rawIdentifier)
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: UUID,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        var entries = readEntries(from: document)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw MLXMemoryServiceError.entryNotFound(id.uuidString)
        }
        entries[index].isArchived = isArchived
        try writeEntries(entries, to: document)
        Self.notifyMemoryEntriesChanged()
        return entries[index]
    }

    public func deleteEntry(
        id: UUID,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws {
        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        var entries = readEntries(from: document)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw MLXMemoryServiceError.entryNotFound(id.uuidString)
        }
        entries.remove(at: index)
        try writeEntries(entries, to: document)
        Self.notifyMemoryEntriesChanged()
    }

    public func globalMemoryFileURL() -> URL {
        globalMemoryDirectoryURLResolved().appendingPathComponent(Self.filename)
    }

    private func memoryDocuments(workspaceRootURL: URL?) -> [MemoryDocument] {
        var documents = [
            MemoryDocument(scope: .global, fileURL: globalMemoryFileURL())
        ]
        if let workspaceRootURL {
            documents.append(
                MemoryDocument(
                    scope: .project,
                    fileURL: workspaceRootURL
                        .standardizedFileURL
                        .appendingPathComponent(Self.filename)
                )
            )
        }
        return documents
    }

    private func memoryDocument(
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryDocument {
        switch scope {
        case .global:
            return MemoryDocument(scope: .global, fileURL: globalMemoryFileURL())
        case .project:
            guard let workspaceRootURL else {
                throw MLXMemoryServiceError.scopeUnavailable("project")
            }
            return MemoryDocument(
                scope: .project,
                fileURL: workspaceRootURL
                    .standardizedFileURL
                    .appendingPathComponent(Self.filename)
            )
        }
    }

    private func readEntries(from document: MemoryDocument) -> [MLXMemoryEntry] {
        guard fileManager.fileExists(atPath: document.fileURL.path),
              let content = try? String(contentsOf: document.fileURL, encoding: .utf8) else {
            return []
        }

        var entries: [MLXMemoryEntry] = []
        var sectionIsArchived = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                sectionIsArchived = line
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveContains("archived")
                continue
            }

            guard line.hasPrefix("- ") else {
                continue
            }

            guard let entry = Self.entry(
                fromBulletLine: String(line.dropFirst(2)),
                scope: document.scope,
                isArchived: sectionIsArchived
            ) else {
                continue
            }
            entries.append(entry)
        }
        return entries
    }

    private static func entry(
        fromBulletLine line: String,
        scope: MLXMemoryScope,
        isArchived: Bool
    ) -> MLXMemoryEntry? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return nil
        }

        let idPrefix = "[id:"
        if trimmedLine.lowercased().hasPrefix(idPrefix),
           let closingBracket = trimmedLine.firstIndex(of: "]") {
            let rawID = trimmedLine[trimmedLine.index(trimmedLine.startIndex, offsetBy: idPrefix.count)..<closingBracket]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = trimmedLine[trimmedLine.index(after: closingBracket)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: rawID), !content.isEmpty else {
                return nil
            }
            return MLXMemoryEntry(
                content: content,
                scope: scope,
                id: id,
                isArchived: isArchived
            )
        }

        return MLXMemoryEntry(
            content: trimmedLine,
            scope: scope,
            isArchived: isArchived
        )
    }

    private func writeEntries(
        _ entries: [MLXMemoryEntry],
        to document: MemoryDocument
    ) throws {
        try fileManager.createDirectory(
            at: document.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let activeEntries = entries.filter { !$0.isArchived }
        let archivedEntries = entries.filter(\.isArchived)
        let content = """
        # MEMORY.md

        ## Active

        \(Self.render(entries: activeEntries))

        ## Archived

        \(Self.render(entries: archivedEntries))
        """
        try content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: document.fileURL, atomically: true, encoding: .utf8)
    }

    private static func render(entries: [MLXMemoryEntry]) -> String {
        guard !entries.isEmpty else {
            return ""
        }
        return entries.map { entry in
            "- [id: \(entry.id.uuidString.uppercased())] \(normalizedBulletContent(entry.content))"
        }
        .joined(separator: "\n")
    }

    private static func normalizedBulletContent(_ content: String) -> String {
        MLXMemoryEntry.normalizedContent(content)
    }

    private func searchScore(entry: MLXMemoryEntry, terms: [String]) -> Int {
        let content = entry.content.lowercased()
        var score = 0
        for term in terms {
            if content.contains(term) {
                score += 10
            }
            if entry.scope.rawValue.contains(term) {
                score += 3
            }
        }
        if entry.scope == .project {
            score += 2
        }
        return score
    }

    private func workspaceRootURL(for workspaceContext: XcodeWorkspaceContext?) -> URL? {
        guard let path = XcodeWorkspaceContext.normalizedProjectRootPath(
            explicitPath: workspaceContext?.workspacePath,
            workspacePath: workspaceContext?.workspacePath
        ) else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func globalMemoryDirectoryURLResolved() -> URL {
        if let globalMemoryDirectoryURL {
            return globalMemoryDirectoryURL.standardizedFileURL
        }

        return MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
    }

}

private struct MemoryDocument {
    let scope: MLXMemoryScope
    let fileURL: URL
}

public enum MLXMemoryServiceError: LocalizedError {
    case missingField(String)
    case scopeUnavailable(String)
    case invalidIdentifier(String)
    case entryNotFound(String)

    public var errorDescription: String? {
        switch self {
        case let .missingField(field):
            return "Missing memory field: \(field)."
        case let .scopeUnavailable(scope):
            return "The \(scope) memory scope is not available in the current context."
        case let .invalidIdentifier(identifier):
            return "Invalid memory identifier: \(identifier)."
        case let .entryNotFound(identifier):
            return "No active memory entry was found for \(identifier)."
        }
    }
}
