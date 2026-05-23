//
//  AgentRuntimeConfiguration.swift
//  MLXCoder
//
//  Created by Codex on 02/05/26.
//

import Foundation

public struct AgentToolAuthorizationRequest: Sendable {
    public let sessionID: String?
    public let toolCallID: String
    public let toolName: String
    public let title: String
    public let kind: String
    public let command: String
    public let workingDirectory: String
}

public typealias AgentToolAuthorizationHandler = @Sendable (AgentToolAuthorizationRequest) async -> Bool

public struct AgentToolCall: Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String
}

public typealias AgentBorrowedToolCall = AgentToolCall
public typealias AgentToolExecutor = @Sendable (AgentToolCall) async throws -> String
public typealias AgentBorrowedToolExecutor = AgentToolExecutor

public struct AgentToolProvider: Sendable {
    public let tools: [ToolDescriptor]
    public let executor: AgentToolExecutor

    public init(
        tools: [ToolDescriptor],
        executor: @escaping AgentToolExecutor
    ) {
        self.tools = ToolDescriptor.canonicalized(tools)
        self.executor = executor
    }
}

public struct AgentRuntimeAttachment: Sendable {
    public enum Kind: String, Sendable {
        case image
        case video
    }

    public let kind: Kind
    public let fileURL: URL?
    public let data: Data?
    public let contentType: String?
    public let originalFilename: String

    public init(
        kind: Kind,
        fileURL: URL? = nil,
        data: Data? = nil,
        contentType: String? = nil,
        originalFilename: String
    ) {
        self.kind = kind
        self.fileURL = fileURL
        self.data = data
        self.contentType = contentType?.nilIfBlank
        self.originalFilename = originalFilename.nilIfBlank ?? "attachment"
    }
}

public struct AgentRuntimeMessage: Sendable {
    public enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    public let attachments: [AgentRuntimeAttachment]

    public init(
        role: Role,
        content: String,
        attachments: [AgentRuntimeAttachment] = []
    ) {
        self.role = role
        self.content = content
        self.attachments = attachments
    }
}

public struct AgentRuntimeConfiguration: Sendable {
    public let modelID: String?
    public let bearerToken: String?
    public let workingDirectory: URL
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
    public let appMode: Bool
    public let toolAuthorizationHandler: AgentToolAuthorizationHandler?

    public init(
        modelID: String?,
        bearerToken: String?,
        workingDirectory: URL,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool,
        appMode: Bool = false,
        toolAuthorizationHandler: AgentToolAuthorizationHandler?
    ) {
        self.modelID = modelID?.nilIfBlank
        self.bearerToken = bearerToken?.nilIfBlank
        self.workingDirectory = workingDirectory
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = generationParameterOverrides.normalized()
        self.maxToolRounds = maxToolRounds
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.appMode = appMode
        self.toolAuthorizationHandler = toolAuthorizationHandler
    }

    public func withModelID(_ modelID: String?) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID?.nilIfBlank,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }

    public func withLocalModelSettings(
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?
    ) -> AgentRuntimeConfiguration {
        withModelSettings(
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides
        )
    }

    public func withModelSettings(
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit.map {
                min(max($0, 1), 1_048_576)
            },
            generationParameterOverrides: generationParameterOverrides?
                .normalized()
                ?? AgentGenerationParameterOverrides(),
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }

    public func withToolAuthorizationHandler(
        _ toolAuthorizationHandler: AgentToolAuthorizationHandler?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }
}

public enum AgentStandaloneSystemPrompt {
    public static func prompt(
        cwd: String,
        memoryToolEnabled: Bool = false,
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil,
        selectedAgentSection: String? = nil,
        selectedSkillSection: String? = nil
    ) -> String {
        let workingDirectory = URL(fileURLWithPath: cwd)
        let agentsNotice = MLXAgentsContextService(
            fileManager: fileManager,
            globalAgentsDirectoryURL: globalAgentsDirectoryURL
        )
        .promptSection(workingDirectory: workingDirectory)
        let agentsSection = [selectedAgentSection, agentsNotice]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "\n\n")
            .nilIfBlank
        return MLXSystemPromptBuilder.standalonePrompt(
            cwd: cwd,
            agentsSection: agentsSection,
            memorySection: memoryToolEnabled ? MLXMemoryService.toolUsagePromptSection() : nil,
            memoryToolEnabled: memoryToolEnabled,
            selectedSkillSection: selectedSkillSection
        )
    }
}

public protocol AgentRuntimeBackend: Actor {
    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func updateSessionOptions(
        id: String,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    )

    func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async

    func updateToolProviders(_ providers: [AgentToolProvider]) async

    func closeSession(id: String)
    func shutdown() async

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String

    func activeToolDescriptors() async -> [DirectToolDescriptor]

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse
}

public extension AgentRuntimeBackend {
    public func updateBorrowedOrchestrationToolExecutor(
        _ executor: AgentBorrowedToolExecutor?
    ) async {}

    public func updateToolProviders(_ providers: [AgentToolProvider]) async {}
}

public extension String {
    public var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
