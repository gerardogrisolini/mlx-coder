import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct ACPCompatibilityTests {
    @Test
    func sessionIDAcceptsACPAndSnakeCaseKeys() {
        #expect(MLXCoderACPBridge.sessionID(from: ["sessionId": "abc"]) == "abc")
        #expect(MLXCoderACPBridge.sessionID(from: ["session_id": "def"]) == "def")
        #expect(MLXCoderACPBridge.sessionID(from: ["id": "ghi"]) == "ghi")
        #expect(MLXCoderACPBridge.sessionID(from: ["sessionId": "   "]) == nil)
    }

    @Test
    func allowedToolsAcceptACPAliasesAndSelectionNames() {
        let allowedTools = MLXCoderACPBridge.allowedToolNames(from: [
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        #expect(allowedTools?.contains("xcode.") == true)
        #expect(allowedTools?.contains("local.exec") == true)
    }

    @Test
    func allowedToolsAcceptDescriptorObjects() {
        let allowedTools = MLXCoderACPBridge.allowedToolNames(from: [
            "tools": [
                ["name": "xcode.BuildProject"],
                ["toolName": "git.status"]
            ] as [[String: Any]]
        ])

        #expect(allowedTools == ["git.status", "xcode.BuildProject"])
    }

    @Test
    func acpVerboseLogFileWritesToSupportLogsDirectory() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-log-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }

        let logFile = try #require(
            ACPVerboseLogFile.open(supportDirectoryURL: supportURL)
        )
        await logFile.write("sample diagnostic")

        let contents = try String(contentsOf: logFile.url, encoding: .utf8)

        #expect(logFile.url.deletingLastPathComponent().lastPathComponent == "logs")
        #expect(logFile.url.lastPathComponent.hasPrefix("acp-"))
        #expect(contents.contains("sample diagnostic"))
    }

    @Test
    func mcpServersParseACPStdioXcodeConfiguration() throws {
        let definitions = MLXCoderACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": "/usr/bin/xcrun",
                    "args": ["mcpbridge"],
                    "env": [
                        [
                            "name": "MCP_XCODE_SESSION_ID",
                            "value": "session-1"
                        ]
                    ]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Xcode")
        #expect(definition.type == "stdio")
        #expect(definition.isXcodeCandidate)
        #expect(definition.configuration.executablePath == "/usr/bin/xcrun")
        #expect(definition.configuration.arguments == ["mcpbridge"])
        #expect(definition.configuration.environment["MCP_XCODE_SESSION_ID"] == "session-1")
        #expect(definition.configuration.usesMCPBridgeExecutable)
    }

    @Test
    func mcpServersParseBareXcrunXcodeConfiguration() throws {
        let definitions = MLXCoderACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "xcode-tools",
                    "command": "xcrun",
                    "args": ["mcpbridge"]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "xcode-tools")
        #expect(definition.isXcodeCandidate)
        #expect(definition.configuration.executablePath == "xcrun")
        #expect(definition.configuration.arguments == ["mcpbridge"])
        #expect(definition.configuration.usesMCPBridgeExecutable)
    }

    @Test
    func mcpServersParseACPHTTPConfiguration() throws {
        let definitions = MLXCoderACPBridge.mcpServerDefinitions(from: [
            "mcp_servers": [
                [
                    "type": "http",
                    "name": "Docs",
                    "url": "https://mcp.example.test/mcp",
                    "headers": [
                        [
                            "name": "Authorization",
                            "value": "Bearer token"
                        ]
                    ]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Docs")
        #expect(definition.type == "http")
        #expect(!definition.isXcodeCandidate)
        #expect(definition.configuration.endpointURL?.absoluteString == "https://mcp.example.test/mcp")
        #expect(definition.configuration.httpHeaders["Authorization"] == "Bearer token")
    }

    @Test
    func mcpServersParseMapConfiguration() throws {
        let definitions = MLXCoderACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                "Xcode": [
                    "type": "stdio",
                    "command": "/usr/bin/xcrun",
                    "args": ["mcpbridge"]
                ] as [String: Any]
            ] as [String: Any]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Xcode")
        #expect(definition.configuration.executablePath == "/usr/bin/xcrun")
        #expect(definition.configuration.arguments == ["mcpbridge"])
        #expect(MLXCoderACPBridge.mcpServerInputSummary(from: [
            "mcpServers": [
                "Xcode": [:] as [String: Any]
            ] as [String: Any]
        ]) == "object(1:Xcode)")
    }

    #if os(macOS)
    @Test
    func localMCPTransportResolvesBareExecutableNamesAndKeepsPATH() throws {
        let configuration = MCPServerConfiguration(
            executablePath: "env",
            arguments: [],
            environment: [
                "MCP_XCODE_SESSION_ID": "session-1",
                "PATH": "/custom/bin"
            ]
        )
        let expectedExecutableURL = try #require(DeveloperToolEnvironment.executableURL(named: "env"))
        let resolvedEnvironment = MCPClient.resolvedEnvironment(for: configuration)
        let resolvedPathParts = Set((resolvedEnvironment["PATH"] ?? "").split(separator: ":").map(String.init))

        #expect(MCPClient.resolvedExecutableURL(for: configuration).path == expectedExecutableURL.path)
        #expect(resolvedEnvironment["MCP_XCODE_SESSION_ID"] == "session-1")
        #expect(resolvedPathParts.contains("/custom/bin"))
        #expect(resolvedPathParts.contains("/usr/bin"))
    }
    #endif

    @Test
    func allowedToolNamesIncludeACPProvidedMCPDescriptors() {
        let allowedTools = MLXCoderACPBridge.allowedToolNames(
            ["local.exec"],
            adding: [
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Xcode: Build",
                    inputSchema: "{}"
                )
            ]
        )

        #expect(allowedTools == ["local.exec", "xcode.BuildProject"])
    }

    @Test
    func newSessionSkipsUnavailableACPProvidedMCPServers() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["shell"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": "/path/that/does/not/exist/mcpbridge",
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(!allowedToolNames.contains("xcode.BuildProject"))
    }

    @Test
    func newSessionConsumesAllowedToolsFromACPParams() async throws {
        let backend = CapturingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend },
            mcpRuntime: Self.xcodeRuntime(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj"),
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("xcode."))
        #expect(allowedToolNames.contains("local.exec"))
        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "verify tools"
        ])
        #expect(await backend.createdAllowedToolNames() == allowedToolNames)
    }

    @Test
    func newSessionDoesNotDiscoverInternalXcodeWhenOnlyACPProvidesXcodeTools() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-client-xcode-mcp-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let executableURL = supportURL.appendingPathComponent("xcode-mcp-fixture")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *initialize*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"XcodeRead","description":"Reads from Xcode","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}}}}]}}'
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let discoveryProbe = XcodeDiscoveryProbe()
        let mcpRuntime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                await discoveryProbe.discovery(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj")
            }
        )
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["shell"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": executableURL.path,
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode.XcodeRead"))
        #expect(await discoveryProbe.count() == 0)
    }

    @Test
    func newSessionExposesDiscoveredXcodeToolsWithoutInjectingPromptContext() async throws {
        let backend = CapturingACPBackend()
        let agent = AgentProfile(
            id: "xcode-agent",
            name: "Xcode Agent",
            tools: ["shell", "xcode"]
        )
        let mcpRuntime = Self.xcodeRuntime(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj")
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agent],
            agentName: agent.name,
            backendFactory: { _, _ in backend },
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace"
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)
        let systemPrompt = try #require(configuration.systemPrompt)
        let descriptors = await mcpRuntime.knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/acp-tools-workspace")
        )

        #expect(allowedToolNames.contains("xcode."))
        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(!systemPrompt.contains("Current Xcode workspace context:"))
        #expect(!systemPrompt.contains("Available Xcode tools in this session:"))
        #expect(!systemPrompt.contains("`xcode.BuildProject`"))
        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "verify Xcode tools"
        ])
        #expect(await backend.createdSystemPrompt()?.contains("`xcode.BuildProject`") != true)
    }

    @Test
    func newSessionIgnoresNonStandardSystemPromptParameter() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-system-prompt-workspace",
            "systemPrompt": "CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let systemPrompt = try #require(configuration.systemPrompt)

        #expect(!systemPrompt.contains("CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"))
    }

    @Test
    func newSessionUsesHostedDefaultThinkingWhenThinkingIsNotProvided() async throws {
        let bridge = try makeBridge(
            models: [
                Self.thinkingModel(defaultThinkingSelection: .high)
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)

        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func newSessionUsesAgentThinkingOverHostedDefault() async throws {
        let model = Self.thinkingModel(defaultThinkingSelection: .medium)
        let agent = AgentProfile(
            id: "thinking-agent",
            name: "Thinking Agent",
            tools: [],
            modelID: model.id,
            thinkingSelection: .high
        )
        let bridge = try makeBridge(
            models: [model],
            availableAgents: [agent],
            agentName: agent.name
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)

        #expect(configuration.modelID == model.id)
        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func newSessionKeepsXcodeSelectionWhenXcodeIsClosed() async throws {
        let mcpRuntime = DirectMCPToolRuntime()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { false }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode."))
        #expect(configuration.systemPrompt?.contains("Available Xcode tools in this session:") != true)
        let descriptors = await mcpRuntime.knownDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/acp-tools-workspace")
        )
        #expect(descriptors.isEmpty)
    }

    @Test
    func newSessionKeepsXcodeSelectionWhenXcodeWorkspaceDiffers() async throws {
        let mcpRuntime = Self.xcodeRuntime(workspacePath: "/tmp/other-workspace/App.xcodeproj")
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.testOnlySessionConfigurations().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode."))
        #expect(configuration.systemPrompt?.contains("Available Xcode tools in this session:") != true)
        let descriptors = await mcpRuntime.knownDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/acp-tools-workspace")
        )
        #expect(descriptors.isEmpty)
    }

    @Test
    func parsedACPXcodeSelectionExposesBorrowedXcodeDescriptors() async throws {
        let allowedTools = try #require(MLXCoderACPBridge.allowedToolNames(from: [
            "allowed_tools": ["xcode"] as [String]
        ]))
        let mcpRuntime = DirectMCPToolRuntime()
        let xcodeExecutor = XcodeToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        await mcpRuntime.installBorrowedXcodeExecutor(
            xcodeExecutor,
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project",
                    inputSchema: "{}"
                )
            ]
        )

        let descriptors = await mcpRuntime.descriptors(
            allowedToolNames: allowedTools
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
    }

    @Test
    func acpProvidedXcodeMCPServerRegistersThroughCentralRuntime() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-xcode-mcp-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let requestURL = supportURL.appendingPathComponent("request.jsonl")
        let executableURL = supportURL.appendingPathComponent("xcode-mcp-fixture")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *initialize*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"XcodeRead","description":"Reads from Xcode","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}}}}]}}'
              ;;
            *tools*call*)
              printf '%s\\n' "$line" > "\(requestURL.path)"
              printf '%s\\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"content":[{"type":"text","text":"ok"}]}}'
              exit 0
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = DirectMCPToolRuntime()
        let descriptors = try await runtime.installExternalMCPServer(
            name: "Xcode",
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            )
        )
        let output = try await runtime.execute(
            toolCall: DirectAgentToolCall(
                id: "call-1",
                name: "xcode.read",
                argumentsObject: ["path": "Sources/App/File.swift"],
                argumentsJSON: #"{"path":"Sources/App/File.swift"}"#
            )
        )
        let capturedRequestData = try Data(contentsOf: requestURL)
        let capturedRequest = try #require(
            JSONSerialization.jsonObject(with: capturedRequestData) as? [String: Any]
        )
        let capturedParams = try #require(capturedRequest["params"] as? [String: Any])
        let capturedArguments = try #require(capturedParams["arguments"] as? [String: Any])

        #expect(descriptors.map(\.name) == ["xcode.XcodeRead"])
        #expect(output == "ok")
        #expect(capturedParams["name"] as? String == "XcodeRead")
        #expect(capturedArguments["filePath"] as? String == "Sources/App/File.swift")
    }

    @Test
    func acpSessionStoreRoundTripsRuntimeSnapshot() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-session-store-\(UUID().uuidString)", isDirectory: true)
        let workspaceURL = supportURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )

        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: "swiftmlx-session-1",
            workingDirectoryPath: workspaceURL.path,
            systemPrompt: "System",
            cacheKey: "cache",
            history: [
                AgentRuntimeMessage(role: .user, content: "Hello"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "Hi",
                    reasoningContent: "Thinking"
                )
            ],
            allowedToolNames: ["local.readFile", "local.exec"],
            thinkingSelection: .medium,
            preserveThinking: true
        )

        let fileURL = try MLXCoderACPSessionStore.save(
            snapshot,
            supportDirectoryURL: supportURL
        )
        #expect(fileURL.pathExtension == MLXCoderACPSessionStore.fileExtension)

        let loadedSnapshot = try MLXCoderACPSessionStore.load(
            sessionID: snapshot.sessionID,
            workingDirectory: workspaceURL,
            supportDirectoryURL: supportURL
        )
        #expect(loadedSnapshot?.sessionID == snapshot.sessionID)
        #expect(loadedSnapshot?.workingDirectoryPath == snapshot.workingDirectoryPath)
        #expect(loadedSnapshot?.systemPrompt == snapshot.systemPrompt)
        #expect(loadedSnapshot?.cacheKey == snapshot.cacheKey)
        #expect(loadedSnapshot?.history == snapshot.history)
        #expect(loadedSnapshot?.allowedToolNames == snapshot.allowedToolNames)
        #expect(loadedSnapshot?.thinkingSelection == snapshot.thinkingSelection)
        #expect(loadedSnapshot?.preserveThinking == snapshot.preserveThinking)
    }

    @Test
    func toolCallUpdatesUseACPv1WireKeys() throws {
        let toolCall = DirectAgentToolCall(
            id: "call_001",
            name: "local.exec",
            argumentsObject: [
                "command": "swift test",
                "workingDirectory": "/tmp/workspace"
            ],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"/tmp/workspace"}"#
        )

        let create = MLXCoderACPBridge.toolCallCreateUpdate(for: toolCall)
        #expect(create["sessionUpdate"] as? String == "tool_call")
        #expect(create["toolCallId"] as? String == "call_001")
        #expect(create["kind"] as? String == "execute")
        #expect(create["status"] as? String == "pending")
        #expect(create["tool_call_id"] == nil)

        let progress = MLXCoderACPBridge.toolCallProgressUpdate(for: toolCall)
        #expect(progress["sessionUpdate"] as? String == "tool_call_update")
        #expect(progress["toolCallId"] as? String == "call_001")
        #expect(progress["status"] as? String == "in_progress")

        let completion = MLXCoderACPBridge.toolCallCompletionUpdate(
            for: toolCall,
            result: DirectAgentToolResult(
                output: "Build complete.",
                summary: "Build complete."
            )
        )
        #expect(completion["sessionUpdate"] as? String == "tool_call_update")
        #expect(completion["toolCallId"] as? String == "call_001")
        #expect(completion["status"] as? String == "completed")
    }

    @Test
    func toolLocationsOmitAncestorWhenSpecificPathExists() throws {
        let root = "/Users/gerardo/Projects/mlx-server"
        let file = "\(root)/Tests/MLXCoderCoreTests/RemoteModelCatalogClientTests.swift"
        let toolCall = DirectAgentToolCall(
            id: "call_read",
            name: "local.readFile",
            argumentsObject: [
                "path": root,
                "file_path": file
            ],
            argumentsJSON: "{}"
        )
        let paths = MLXCoderACPBridge.toolLocations(for: toolCall).compactMap {
            $0["path"] as? String
        }

        #expect(paths == [file])
    }

    @Test
    func permissionResponsesAcceptAlternateACPShapes() {
        let cases: [(JSONValue, String)] = [
            (.string("allow_once"), "allow_once"),
            (.object(["optionId": .string("allow_always")]), "allow_always"),
            (.object(["optionID": .string("allow_upper")]), "allow_upper"),
            (.object(["option_id": .string("allow_snake")]), "allow_snake"),
            (.object(["confirmKey": .string("allow_confirm")]), "allow_confirm"),
            (.object(["confirm_key": .string("allow_confirm_snake")]), "allow_confirm_snake"),
            (.object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string("reject_once")
                ])
            ]), "reject_once"),
            (.object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "option_id": .string("reject_always")
                ])
            ]), "reject_always"),
            (.object([
                "selected": .object([
                    "confirm_key": .string("allow_selected")
                ])
            ]), "allow_selected")
        ]

        for (value, expected) in cases {
            #expect(ACPPermissionBroker.permissionOptionID(from: value) == expected)
        }
    }

            @Test
    func cancelledPermissionOutcomeDoesNotSelectOption() {
        let value = JSONValue.object([
            "outcome": .object([
                "outcome": .string("cancelled")
            ])
        ])

        #expect(ACPPermissionBroker.permissionOptionID(from: value) == nil)
    }

    @Test
    func acpLocalExecAlwaysPermissionUsesExecutableOnly() {
        let localExecRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_exec",
            toolName: "local.exec",
            title: "Run swift test --filter One",
            kind: "execute",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )
        let secondLocalExecRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_exec_2",
            toolName: "local.exec",
            title: "Run swift test --filter Two",
            kind: "execute",
            command: "swift test --filter Two",
            workingDirectory: "/tmp/project"
        )
        let nonLocalRequest = AgentToolAuthorizationRequest(
            sessionID: "session",
            toolCallID: "call_custom",
            toolName: "custom.tool",
            title: "Run custom tool",
            kind: "execute",
            command: "swift test --filter One",
            workingDirectory: "/tmp/project"
        )

        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: localExecRequest) == "swift")
        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: secondLocalExecRequest) == "swift")
        #expect(ACPPermissionBroker.permissionCacheCommandIdentity(for: nonLocalRequest) == "swift test --filter One")
    }

    @Test
    func sessionUpdatesWrapPayloadInStandardNotificationShape() {
        let usageUpdate = MLXCoderACPBridge.usageUpdate(
            for: DirectAgentContextWindowStatus(
                usedTokens: 42,
                maxTokens: 4096,
                modelID: "local-model",
                isApproximate: true
            )
        )

        let notification = JSONValue.acpValue(from: [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": "session-1",
                "update": usageUpdate ?? [:]
            ]
        ])

        let object = notification.mlxObjectValue
        #expect(object?["method"]?.acpStringValue == "session/update")
        let params = object?["params"]?.mlxObjectValue
        #expect(params?["sessionId"]?.acpStringValue == "session-1")
        let update = params?["update"]?.mlxObjectValue
        #expect(update?["sessionUpdate"]?.acpStringValue == "usage_update")
        #expect(update?["used"]?.intValue == 42)
        #expect(update?["size"]?.intValue == 4096)
        let meta = update?["_meta"]?.mlxObjectValue
        #expect(meta?["modelID"]?.acpStringValue == "local-model")
    }

    @Test
    func imagePromptBlocksAreConvertedToAttachments() {
        let promptBlocks: [Any] = [
            [
                "type": "image",
                "mimeType": "image/png",
                "data": "AQID"
            ] as [String: Any]
        ]
        let attachments = MLXCoderACPBridge.promptAttachments(
            from: promptBlocks,
            renderedPromptText: "",
            cwd: "/tmp"
        )

        #expect(attachments.count == 1)
        #expect(attachments.first?.kind == .image)
        #expect(attachments.first?.contentType == "image/png")
        #expect(attachments.first?.data == Data([1, 2, 3]))
    }
}

private extension ACPCompatibilityTests {
    @Test
    func configOptionsIncludeThinkingForThinkingModels() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "thinking-model",
                    kind: .remoteAPI,
                    title: "Thinking Model",
                    modelID: "local/thinking-model",
                    thinkingOptions: [.off, .medium, .high],
                    defaultThinkingSelection: .medium
                )
            ]
        )

                        let values = await bridge.testThinkingOptionValues(for: "thinking-model")

        #expect(values.currentValue == "medium")
        #expect(values.optionValues == ["off", "medium", "high"])
    }

    @Test
    func configOptionsOmitThinkingForModelsWithoutThinking() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "plain-model",
                    kind: .remoteAPI,
                    modelID: "local/plain-model"
                )
            ]
        )

                        let hasThinking = await bridge.testHasThinkingOption(for: "plain-model")

        #expect(!hasThinking)
    }

    @Test
    func sessionLifecycleResultUsesSessionThinkingSelection() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "thinking-model",
                    kind: .remoteAPI,
                    modelID: "local/thinking-model",
                    thinkingOptions: [.off, .medium, .high],
                    defaultThinkingSelection: .medium
                )
            ]
        )
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "session-thinking",
            modelID: "thinking-model",
                                    bearerToken: nil,
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            thinkingSelection: .high,
            preserveThinking: false
        )
                        await bridge.installTestSession(configuration)

                        let currentValue = await bridge.testLifecycleThinkingCurrentValue(
            sessionID: "session-thinking"
        )

        #expect(currentValue == "high")
    }

    func makeBridge(
        models: [AgentSettingsModelManifest],
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles(),
        agentName: String? = nil,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        mcpRuntime: DirectMCPToolRuntime = DirectMCPToolRuntime(),
        xcodeIsRunning: @escaping @Sendable () -> Bool = { false }
    ) throws -> MLXCoderACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: models.first?.id ?? "model",
            agentName: agentName,
            availableAgents: availableAgents,
            availableModels: models,
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        return MLXCoderACPBridge(
            configuration: configuration,
            writer: ACPWriter(),
            backendFactory: backendFactory,
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: xcodeIsRunning
        )
    }

    static func xcodeRuntime(workspacePath: String) -> DirectMCPToolRuntime {
        DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                DirectMCPToolRuntime.XcodeDiscovery(
                    executor: XcodeToolExecutor(
                        configuration: MCPServerConfiguration(
                            executablePath: "/usr/bin/false",
                            arguments: [],
                            environment: [:]
                        )
                    ),
                    tools: [
                        ToolDescriptor(
                            name: "BuildProject",
                            description: "Builds an Xcode project",
                            inputSchema: "{}"
                        )
                    ],
                    workspaceContexts: [
                        XcodeWorkspaceContext(
                            workspacePath: workspacePath,
                            defaultTabIdentifier: nil
                        )
                    ],
                    ownsExecutor: false
                )
            }
        )
    }

    static func thinkingModel(
        defaultThinkingSelection: AgentThinkingSelection
    ) -> AgentSettingsModelManifest {
        let provider = AgentRemoteProvider(
            name: "mlx-server",
            baseURL: "http://127.0.0.1",
            modelID: "local/thinking-model"
        )
        return AgentSettingsModelManifest(
            id: "thinking-model",
            kind: .remoteAPI,
            modelID: "local/thinking-model",
            provider: provider,
            thinkingOptions: [.off, .medium, .high],
            defaultThinkingSelection: defaultThinkingSelection
        )
    }
}

private extension MLXCoderACPBridge {
    func testOnlySessionConfigurations() -> [AgentCoreSessionConfiguration] {
        sessions.values.map(\.configuration)
    }

    func installTestSession(_ configuration: AgentCoreSessionConfiguration) {
        sessions[configuration.sessionID] = sessionState(configuration: configuration)
    }

    func testThinkingOptionValues(
        for modelID: String
    ) -> (currentValue: String?, optionValues: [String]?) {
        guard let thinking = configOptions(for: modelID).first(where: {
            $0["id"] as? String == "thinking"
        }) else {
            return (nil, nil)
        }
        let optionValues = (thinking["options"] as? [[String: Any]])?.compactMap { option in
            option["value"] as? String
        }
        return (thinking["currentValue"] as? String, optionValues)
    }

    func testHasThinkingOption(for modelID: String) -> Bool {
        configOptions(for: modelID).contains { option in
            option["id"] as? String == "thinking"
        }
    }

    func testLifecycleThinkingCurrentValue(sessionID: String) -> String? {
        let result = sessionLifecycleResult(sessionID: sessionID)
        let options = result["configOptions"] as? [[String: Any]]
        let thinking = options?.first { option in
            option["id"] as? String == "thinking"
        }
        return thinking?["currentValue"] as? String
    }
}

private actor XcodeDiscoveryProbe {
    private var callCount = 0

    func discovery(workspacePath: String) -> DirectMCPToolRuntime.XcodeDiscovery {
        callCount += 1
        return DirectMCPToolRuntime.XcodeDiscovery(
            executor: XcodeToolExecutor(
                configuration: MCPServerConfiguration(
                    executablePath: "/usr/bin/false",
                    arguments: [],
                    environment: [:]
                )
            ),
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project",
                    inputSchema: "{}"
                )
            ],
            workspaceContexts: [
                XcodeWorkspaceContext(
                    workspacePath: workspacePath,
                    defaultTabIdentifier: nil
                )
            ],
            ownsExecutor: false
        )
    }

    func count() -> Int {
        callCount
    }
}

private actor CapturingACPBackend: AgentRuntimeBackend {
    private var allowedToolNames: Set<String>?
    private var systemPrompt: String?

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        self.allowedToolNames = allowedToolNames
        self.systemPrompt = systemPrompt
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        self.allowedToolNames = allowedToolNames
        self.systemPrompt = systemPrompt
    }

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test-model")
    }

    func createdAllowedToolNames() -> Set<String>? {
        allowedToolNames
    }

    func createdSystemPrompt() -> String? {
        systemPrompt
    }
}
