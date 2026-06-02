//
//  MLXCoderACPSessionStore.swift
//  MLXCoder
//

import Foundation

public struct MLXCoderACPSavedSession: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionID: String
    public let workingDirectoryPath: String
    public let savedAt: Date
    public let modelID: String?
    public let systemPrompt: String?
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        version: Int = Self.currentVersion,
        sessionID: String,
        workingDirectoryPath: String,
        savedAt: Date,
        modelID: String? = nil,
        systemPrompt: String?,
        cacheKey: String?,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        self.version = version
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.workingDirectoryPath = URL(fileURLWithPath: workingDirectoryPath)
            .standardizedFileURL
            .path
        self.savedAt = savedAt
        self.modelID = modelID?.nilIfBlank
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.cacheKey = cacheKey?.nilIfBlank
        self.history = history
        self.allowedToolNames = allowedToolNames
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }

    public init(snapshot: AgentRuntimeSessionSnapshot, savedAt: Date = Date()) {
        self.init(
            sessionID: snapshot.sessionID,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            savedAt: savedAt,
            modelID: snapshot.modelID,
            systemPrompt: snapshot.systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: snapshot.history,
            allowedToolNames: snapshot.allowedToolNames,
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
    }

    public var snapshot: AgentRuntimeSessionSnapshot {
        AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }
}

public enum MLXCoderACPSessionStore {
    public static let fileExtension = "acpsession"

    @discardableResult
    public static func save(
        _ snapshot: AgentRuntimeSessionSnapshot,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> URL {
        let session = MLXCoderACPSavedSession(snapshot: snapshot)
        try validate(session)
        let directoryURL = sessionsDirectoryURL(
            for: URL(fileURLWithPath: session.workingDirectoryPath),
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let fileURL = sessionFileURL(
            sessionID: session.sessionID,
            workingDirectory: URL(fileURLWithPath: session.workingDirectoryPath),
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(session)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    public static func load(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) throws -> AgentRuntimeSessionSnapshot? {
        let fileURL = sessionFileURL(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try load(from: fileURL).snapshot
    }

    public static func load(from fileURL: URL) throws -> MLXCoderACPSavedSession {
        let data = try Data(contentsOf: fileURL)
        let session = try PropertyListDecoder().decode(
            MLXCoderACPSavedSession.self,
            from: data
        )
        try validate(session)
        return session
    }

    public static func sessionFileURL(
        sessionID: String,
        workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> URL {
        sessionsDirectoryURL(
            for: workingDirectory,
            fileManager: fileManager,
            supportDirectoryURL: supportDirectoryURL
        )
        .appendingPathComponent(filename(for: sessionID))
    }

    public static func sessionsDirectoryURL(
        for workingDirectory: URL,
        fileManager: FileManager = .default,
        supportDirectoryURL: URL? = nil
    ) -> URL {
        (supportDirectoryURL?.standardizedFileURL
            ?? MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager))
            .appendingPathComponent("acp-sessions", isDirectory: true)
            .appendingPathComponent(
                MLXTerminalSessionStore.projectKey(for: workingDirectory),
                isDirectory: true
            )
    }

    public static func filename(for sessionID: String) -> String {
        "\(MLXTerminalSessionStore.filenameStem(for: sessionID)).\(fileExtension)"
    }

    private static func validate(_ session: MLXCoderACPSavedSession) throws {
        guard session.version == MLXCoderACPSavedSession.currentVersion else {
            throw MLXCoderACPSessionStoreError.unsupportedVersion(session.version)
        }
        guard session.sessionID.nilIfBlank != nil else {
            throw MLXCoderACPSessionStoreError.emptySessionID
        }
        guard session.workingDirectoryPath.nilIfBlank != nil else {
            throw MLXCoderACPSessionStoreError.emptyWorkingDirectory
        }
    }
}

public enum MLXCoderACPSessionStoreError: LocalizedError, Equatable {
    case emptySessionID
    case emptyWorkingDirectory
    case unsupportedVersion(Int)

    public var errorDescription: String? {
        switch self {
        case .emptySessionID:
            return "ACP session snapshot is missing a session id."
        case .emptyWorkingDirectory:
            return "ACP session snapshot is missing a working directory."
        case let .unsupportedVersion(version):
            return "Unsupported ACP session file version: \(version)."
        }
    }
}
