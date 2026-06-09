//
//  DirectMCPToolRuntime.swift
//  MLXCoder
//
//  Created by Codex on 02/05/26.
//

import Foundation

public actor DirectMCPToolRuntime {
    public struct XcodeDiscovery: Sendable {
        public let executor: XcodeToolExecutor
        public let tools: [ToolDescriptor]
        public let workspaceContexts: [XcodeWorkspaceContext]
        public let ownsExecutor: Bool

        public init(
            executor: XcodeToolExecutor,
            tools: [ToolDescriptor],
            workspaceContexts: [XcodeWorkspaceContext],
            ownsExecutor: Bool = true
        ) {
            self.executor = executor
            self.tools = tools
            self.workspaceContexts = workspaceContexts
            self.ownsExecutor = ownsExecutor
        }
    }

    public typealias XcodeDiscoveryProvider = @Sendable () async -> XcodeDiscovery?

    private enum ServerFamily: Hashable {
        case xcode
        case figma
    }

    private enum Backend {
        case xcode(XcodeToolExecutor)
        case remote(RemoteMCPToolExecutor)

        func execute(_ request: ToolRequest) async throws -> ToolExecutionOutput {
            switch self {
            case let .xcode(executor):
                return try await executor.execute(request)
            case let .remote(executor):
                return try await executor.execute(request)
            }
        }

        func disconnect() async {
            switch self {
            case let .xcode(executor):
                await executor.disconnect()
            case let .remote(executor):
                await executor.disconnect()
            }
        }
    }

    private struct Server {
        let family: ServerFamily
        let toolPrefix: String
        let backend: Backend
        let descriptors: [DirectToolDescriptor]
        let workspaceRootPath: String?
        let ownsBackend: Bool

        func disconnectIfOwned() async {
            guard ownsBackend else {
                return
            }
            await backend.disconnect()
        }
    }

    private var didAttemptXcodeDiscovery = false
    private var didAttemptFigmaDiscovery = false
    private var servers: [Server] = []
    private let autoDiscoverExternalConnectors: Bool
    private let xcodeDiscoveryProvider: XcodeDiscoveryProvider

    public init(
        autoDiscoverExternalConnectors: Bool = false,
        xcodeDiscoveryProvider: @escaping XcodeDiscoveryProvider = DirectMCPToolRuntime.defaultXcodeDiscovery
    ) {
        self.autoDiscoverExternalConnectors = autoDiscoverExternalConnectors
        self.xcodeDiscoveryProvider = xcodeDiscoveryProvider
    }

    deinit {
        let servers = self.servers
        Task {
            for server in servers {
                await server.disconnectIfOwned()
            }
        }
    }

    public func shutdown() async {
        let currentServers = servers
        servers.removeAll()
        didAttemptXcodeDiscovery = false
        didAttemptFigmaDiscovery = false
        for server in currentServers {
            await server.disconnectIfOwned()
        }
    }

    public func installBorrowedXcodeExecutor(
        _ executor: XcodeToolExecutor,
        tools: [ToolDescriptor]
    ) async {
        let descriptors = ToolDescriptor.canonicalized(tools)
            .map { tool in
                let name = tool.name.hasPrefix("xcode.")
                    ? tool.name
                    : "xcode.\(tool.name)"
                return DirectToolDescriptor(
                    name: name,
                    description: tool.description.hasPrefix("Xcode:")
                        ? tool.description
                        : "Xcode: \(tool.description)",
                    inputSchema: tool.inputSchema
                )
            }

        let previousXcodeServers = servers.filter { $0.family == .xcode }
        servers.removeAll { $0.family == .xcode }
        didAttemptXcodeDiscovery = true

        for server in previousXcodeServers {
            await server.disconnectIfOwned()
        }

        guard !descriptors.isEmpty else {
            return
        }

        servers.append(
            Server(
                family: .xcode,
                toolPrefix: "xcode.",
                backend: .xcode(executor),
                descriptors: descriptors,
                workspaceRootPath: nil,
                ownsBackend: false
            )
        )
    }

    public func descriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await discoverIfNeeded(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        return knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func discoverDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> [DirectToolDescriptor] {
        await discoverIfNeeded(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            force: true
        )
        return knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
    }

    public func knownDescriptors(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) -> [DirectToolDescriptor] {
        guard let allowedToolNames else {
            return servers
                .filter {
                    serverMatchesPreferredWorkspace(
                        $0,
                        preferredWorkspaceRootURL: preferredWorkspaceRootURL
                    )
                }
                .flatMap(\.descriptors)
        }

        guard !allowedToolNames.isEmpty else {
            return []
        }

        let requestedFamilies = Self.discoveryServerFamilies(
            allowedToolNames: allowedToolNames
        )
        guard !requestedFamilies.isEmpty else {
            return []
        }

        return servers
            .filter { requestedFamilies.contains($0.family) }
            .filter {
                serverMatchesPreferredWorkspace(
                    $0,
                    preferredWorkspaceRootURL: preferredWorkspaceRootURL
                )
            }
            .flatMap(\.descriptors)
    }

    public func canExecute(
        toolName: String,
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil
    ) async -> Bool {
        let discoveryToolNames = allowedToolNames ?? [toolName]
        await discoverIfNeeded(
            allowedToolNames: discoveryToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        return serverAndToolName(for: toolName) != nil
    }

    public func execute(toolCall: DirectAgentToolCall) async throws -> String {
        guard let (server, rawToolName) = serverAndToolName(for: toolCall.name) else {
            throw DirectMCPToolRuntimeError.unknownTool(toolCall.name)
        }

        let request = ToolRequest(
            name: rawToolName,
            arguments: Self.jsonValueArguments(from: toolCall.argumentsObject)
        )
        let normalizedRequest: ToolRequest
        switch server.family {
        case .xcode:
            normalizedRequest = XcodeToolRequestCompatibility.normalize(request) ?? request
        case .figma:
            normalizedRequest = request
        }

        let output = try await server.backend.execute(normalizedRequest)
        return output.text
    }

    private func discoverIfNeeded(
        allowedToolNames: Set<String>? = nil,
        preferredWorkspaceRootURL: URL? = nil,
        force: Bool = false
    ) async {
        for family in Self.discoveryServerFamilies(allowedToolNames: allowedToolNames) {
            await discoverFamilyIfNeeded(
                family,
                preferredWorkspaceRootURL: preferredWorkspaceRootURL,
                force: force
            )
        }
    }

    public static func discoveryFamilies(
        allowedToolNames: Set<String>?
    ) -> Set<String> {
        let families = discoveryServerFamilies(allowedToolNames: allowedToolNames)
        return Set(families.map {
            switch $0 {
            case .xcode:
                return "xcode"
            case .figma:
                return "figma"
            }
        })
    }

    private static func discoveryServerFamilies(
        allowedToolNames: Set<String>?
    ) -> Set<ServerFamily> {
        guard let allowedToolNames else {
            return [.xcode, .figma]
        }

        var families = Set<ServerFamily>()
        for toolName in allowedToolNames {
            if isXcodeToolName(toolName) {
                families.insert(.xcode)
            }
            if toolName.hasPrefix("figma.") {
                families.insert(.figma)
            }
        }
        return families
    }

    public static func isXcodeToolName(_ toolName: String) -> Bool {
        if toolName.hasPrefix("xcode.") || toolName.hasPrefix("Xcode") {
            return true
        }
        return unprefixedXcodeToolNames.contains(toolName)
    }

    private static let unprefixedXcodeToolNames: Set<String> = [
        "BuildProject",
        "DocumentationSearch",
        "ExecuteSnippet",
        "GetBuildLog",
        "GetTestList",
        "RenderPreview",
        "RunAllTests",
        "RunSomeTests"
    ]

    private func discoverFamilyIfNeeded(
        _ family: ServerFamily,
        preferredWorkspaceRootURL: URL?,
        force: Bool
    ) async {
        guard force || autoDiscoverExternalConnectors else {
            return
        }

        switch family {
        case .xcode:
            if let existingServer = servers.first(where: { $0.family == .xcode }),
               serverMatchesPreferredWorkspace(
                   existingServer,
                   preferredWorkspaceRootURL: preferredWorkspaceRootURL
               ) {
                return
            }
            let previousXcodeServers = servers.filter { $0.family == .xcode }
            guard force || !didAttemptXcodeDiscovery || !previousXcodeServers.isEmpty else {
                return
            }
            servers.removeAll { $0.family == .xcode }
            didAttemptXcodeDiscovery = true
            for server in previousXcodeServers {
                await server.disconnectIfOwned()
            }
            if let xcodeServer = await discoverXcodeServer(
                preferredWorkspaceRootURL: preferredWorkspaceRootURL
            ) {
                servers.append(xcodeServer)
            }
        case .figma:
            guard force || !didAttemptFigmaDiscovery else {
                return
            }
            guard !servers.contains(where: { $0.family == .figma }) else {
                return
            }
            didAttemptFigmaDiscovery = true
            if let figmaServer = await discoverFigmaServer() {
                servers.append(figmaServer)
            }
        }
    }

    private func discoverXcodeServer(
        preferredWorkspaceRootURL: URL?
    ) async -> Server? {
        guard let discovery = await xcodeDiscoveryProvider() else {
            return nil
        }

        let tools = ToolDescriptor.canonicalized(discovery.tools)
        guard !tools.isEmpty else {
            if discovery.ownsExecutor {
                await discovery.executor.disconnect()
            }
            return nil
        }

        guard let matchedWorkspaceContext = matchedXcodeWorkspaceContext(
            in: discovery.workspaceContexts,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        ) else {
            if discovery.ownsExecutor {
                await discovery.executor.disconnect()
            }
            return nil
        }

        return Server(
            family: .xcode,
            toolPrefix: "xcode.",
            backend: .xcode(discovery.executor),
            descriptors: tools.map { tool in
                DirectToolDescriptor(
                    name: "xcode.\(tool.name)",
                    description: "Xcode: \(tool.description)",
                    inputSchema: tool.inputSchema
                )
            },
            workspaceRootPath: matchedWorkspaceContext.normalizedWorkspaceRootPath,
            ownsBackend: discovery.ownsExecutor
        )
    }

    private func discoverFigmaServer() async -> Server? {
        guard await MCPServerConfiguration.isFigmaDesktopServerRunning() else {
            return nil
        }

        let executor = RemoteMCPToolExecutor(
            configuration: .figmaDesktopLocal(),
            toolNamePrefix: "figma."
        )
        do {
            let tools = ToolDescriptor.canonicalized(
                try await executor.loadTools()
            )
            guard !tools.isEmpty else {
                await executor.disconnect()
                return nil
            }

            return Server(
                family: .figma,
                toolPrefix: "figma.",
                backend: .remote(executor),
                descriptors: tools.map { tool in
                    DirectToolDescriptor(
                        name: tool.name,
                        description: "Figma: \(tool.description)",
                        inputSchema: tool.inputSchema
                    )
                },
                workspaceRootPath: nil,
                ownsBackend: true
            )
        } catch {
            await executor.disconnect()
            return nil
        }
    }

    public static func defaultXcodeDiscovery() async -> XcodeDiscovery? {
        guard MCPServerConfiguration.isXcodeRunning(),
              let configuration = MCPServerConfiguration.xcodeFromEnvironment() else {
            return nil
        }

        let executor = XcodeToolExecutor(configuration: configuration)
        do {
            let tools = try await executor.loadTools()
            let workspaceContexts = try await executor.loadWorkspaceContexts()
            return XcodeDiscovery(
                executor: executor,
                tools: tools,
                workspaceContexts: workspaceContexts
            )
        } catch {
            await executor.disconnect()
            return nil
        }
    }

    private func matchedXcodeWorkspaceContext(
        in contexts: [XcodeWorkspaceContext],
        preferredWorkspaceRootURL: URL?
    ) -> XcodeWorkspaceContext? {
        guard let preferredWorkspaceRootURL else {
            return contexts.first ?? XcodeWorkspaceContext(
                workspacePath: nil,
                defaultTabIdentifier: nil
            )
        }

        let preferredRootPath = preferredWorkspaceRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return contexts.first { context in
            XcodeWorkspaceContext.workspaceRootPath(
                context.normalizedWorkspaceRootPath,
                matchesPreferredRootPath: preferredRootPath
            )
        }
    }

    private func serverMatchesPreferredWorkspace(
        _ server: Server,
        preferredWorkspaceRootURL: URL?
    ) -> Bool {
        guard server.family == .xcode else {
            return true
        }
        guard let preferredWorkspaceRootURL,
              let workspaceRootPath = server.workspaceRootPath else {
            return true
        }
        let preferredRootPath = preferredWorkspaceRootURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        return XcodeWorkspaceContext.workspaceRootPath(
            workspaceRootPath,
            matchesPreferredRootPath: preferredRootPath
        )
    }

    private func serverAndToolName(for toolName: String) -> (Server, String)? {
        for server in servers {
            guard let rawToolName = rawToolName(toolName, for: server) else {
                continue
            }
            return (server, rawToolName)
        }
        return nil
    }

    private func rawToolName(_ toolName: String, for server: Server) -> String? {
        if toolName.hasPrefix(server.toolPrefix) {
            let rawToolName = String(toolName.dropFirst(server.toolPrefix.count))
            if server.descriptors.contains(where: { $0.name == toolName }) {
                return rawToolName
            }
            if server.family == .xcode,
               let canonicalToolName = Self.canonicalXcodeToolName(for: toolName),
               server.descriptors.contains(where: { $0.name == "\(server.toolPrefix)\(canonicalToolName)" }) {
                return canonicalToolName
            }
            return nil
        }

        guard server.family == .xcode,
              let canonicalToolName = Self.canonicalXcodeToolName(for: toolName),
              server.descriptors.contains(where: { $0.name == "\(server.toolPrefix)\(canonicalToolName)" }) else {
            return nil
        }
        return canonicalToolName
    }

    public static func canonicalXcodeToolName(for toolName: String) -> String? {
        let request = ToolRequest(name: toolName, arguments: [:])
        if let normalized = XcodeToolRequestCompatibility.normalize(request) {
            return normalized.name
        }

        if toolName.hasPrefix("xcode.") {
            let unprefixedName = String(toolName.dropFirst("xcode.".count))
            if let normalized = XcodeToolRequestCompatibility.normalize(
                ToolRequest(name: unprefixedName, arguments: [:])
            ) {
                return normalized.name
            }
        }

        return nil
    }

    private static func jsonValueArguments(from object: [String: Any]) -> [String: JSONValue] {
        guard case let .object(arguments) = JSONValue(jsonObject: object) else {
            return [:]
        }
        return arguments
    }
}

private enum DirectMCPToolRuntimeError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case let .unknownTool(name):
            return "Unknown MCP tool: \(name)"
        }
    }
}
