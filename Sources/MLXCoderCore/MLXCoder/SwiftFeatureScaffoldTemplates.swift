//
//  SwiftFeatureScaffoldTemplates.swift
//  MLXCoder
//

import Foundation

extension SwiftFeatureRuntime {
    enum ScaffoldTemplate {
        case basic
        case mcpBridge
    }

    static func scaffoldTemplate(arguments: [String: Any]) -> ScaffoldTemplate {
        let rawValue = arguments
            .string("template", "kind", "scaffoldTemplate", "scaffold_template")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch rawValue {
        case "mcp", "mcp-bridge", "mcp_bridge", "mcpbridge":
            return .mcpBridge
        default:
            return .basic
        }
    }

    static func defaultScaffoldDescription(
        template: ScaffoldTemplate,
        displayName: String
    ) -> String {
        switch template {
        case .basic:
            return "Swift feature generated for mlx-coder."
        case .mcpBridge:
            return "Swift MCP bridge feature for \(displayName)."
        }
    }

    static func normalizedToolPrefix(_ rawPrefix: String) -> String {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            return prefix
        }
        return prefix.hasSuffix(".") ? prefix : "\(prefix)."
    }

    static func validateMCPBridgeToolPrefix(_ prefix: String) throws {
        guard prefix.nilIfBlank != nil else {
            throw DirectToolError.permissionDenied("MCP bridge toolPrefix cannot be empty.")
        }
        if prefix.hasPrefix("feature.") {
            throw DirectToolError.permissionDenied(
                "Tool namespace 'feature.' is reserved for kernel feature management: \(prefix)"
            )
        }
        if prefix.hasPrefix("local.") || prefix.hasPrefix("text.") {
            throw DirectToolError.permissionDenied(
                "Tool prefix '\(prefix)' conflicts with a core tool namespace."
            )
        }
    }

    static func defaultMLXServerPackagePath(fileManager: FileManager) -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        if fileManager.fileExists(
            atPath: sourceURL.appendingPathComponent("Package.swift").path
        ) {
            return sourceURL.path
        }

        let workingDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        if fileManager.fileExists(
            atPath: workingDirectoryURL.appendingPathComponent("Package.swift").path
        ) {
            return workingDirectoryURL.path
        }

        return sourceURL.path
    }

    static func stringArrayArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [String] {
        for key in keys {
            if let values = arguments[key] as? [String] {
                return values.compactMap(\.nilIfBlank)
            }
            if let values = arguments[key] as? [Any] {
                return values.compactMap { value in
                    String(describing: value).nilIfBlank
                }
            }
            if let value = arguments[key] as? String {
                let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedValue.isEmpty else {
                    return []
                }
                if trimmedValue.contains("\n") {
                    return trimmedValue
                        .split(separator: "\n")
                        .compactMap { String($0).nilIfBlank }
                }
                return [trimmedValue]
            }
        }
        return []
    }

    static func stringDictionaryArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [String: String] {
        for key in keys {
            if let values = arguments[key] as? [String: String] {
                return values.filter { !$0.key.isEmpty }
            }
            if let values = arguments[key] as? [String: Any] {
                var output: [String: String] = [:]
                for (entryKey, value) in values where !entryKey.isEmpty {
                    output[entryKey] = String(describing: value)
                }
                return output
            }
        }
        return [:]
    }

    static func targetName(for id: String) -> String {
        let words = id
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        let name = words.map { word in
            word.prefix(1).uppercased() + word.dropFirst()
        }.joined()
        guard let first = name.first, first.isLetter else {
            return "Feature\(name.nilIfBlank ?? "Generated")"
        }
        return name.nilIfBlank ?? "GeneratedFeature"
    }

    static func defaultToolPrefix(for id: String) -> String {
        let normalized = id
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let value = String(normalized)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.nilIfBlank ?? "generated"
    }

    static func packageManifestContents(
        productName: String,
        targetName: String
    ) -> String {
        """
        // swift-tools-version: \(generatedSwiftToolsVersion)

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            platforms: [
                .macOS(.v26)
            ],
            products: [
                .executable(
                    name: "\(productName)",
                    targets: ["\(targetName)"]
                )
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)"
                )
            ]
        )
        """
    }

    static func mcpBridgePackageManifestContents(
        productName: String,
        targetName: String,
        mlxServerPackagePath: String
    ) -> String {
        """
        // swift-tools-version: \(generatedSwiftToolsVersion)

        import PackageDescription

        let package = Package(
            name: "\(productName)",
            platforms: [
                .macOS(.v26)
            ],
            products: [
                .executable(
                    name: "\(productName)",
                    targets: ["\(targetName)"]
                )
            ],
            dependencies: [
                .package(path: \(swiftStringLiteral(mlxServerPackagePath)))
            ],
            targets: [
                .executableTarget(
                    name: "\(targetName)",
                    dependencies: [
                        .product(name: "MLXCoderCore", package: "mlx-server"),
                        .product(name: "MLXFeatureKit", package: "mlx-server")
                    ]
                )
            ]
        )
        """
    }

    static func featureMainContents(
        toolName: String,
        toolDescription: String
    ) -> String {
        let escapedToolName = swiftStringLiteral(toolName)
        let escapedDescription = swiftStringLiteral(toolDescription)
        return #"""
        import Foundation
        #if canImport(Darwin)
        import Darwin
        #elseif canImport(Glibc)
        import Glibc
        #endif

        private let generatedToolName = \#(escapedToolName)
        private let generatedToolDescription = \#(escapedDescription)
        private let generatedInputSchema = #"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#

        private struct ToolDescriptor: Codable {
            let name: String
            let description: String
            let inputSchema: String
        }

        private struct ListToolsResponse: Codable {
            let tools: [ToolDescriptor]
        }

        private struct InvocationResponse: Codable {
            let ok: Bool
            let output: String?
            let error: String?
        }

        private struct EchoInput: Decodable {
            let text: String?
        }

        struct InvocationContext {
            let workingDirectory: URL

            func resolvePath(_ path: String) -> URL {
                let expandedPath = NSString(string: path).expandingTildeInPath
                if expandedPath.hasPrefix("/") {
                    return URL(fileURLWithPath: expandedPath).standardizedFileURL
                }
                return workingDirectory
                    .appendingPathComponent(expandedPath)
                    .standardizedFileURL
            }
        }

        @main
        struct GeneratedFeatureMain {
            static func main() async {
                do {
                    let parsed = ParsedArguments(arguments: Array(CommandLine.arguments.dropFirst()))
                    switch parsed.command {
                    case .listTools:
                        try writeJSON(
                            ListToolsResponse(
                                tools: [
                                    ToolDescriptor(
                                        name: generatedToolName,
                                        description: generatedToolDescription,
                                        inputSchema: generatedInputSchema
                                    )
                                ]
                            )
                        )
                    case let .invoke(toolName, workingDirectory):
                        let inputData = FileHandle.standardInput.readDataToEndOfFile()
                        let output = try invoke(
                            toolName: toolName,
                            inputData: inputData,
                            context: InvocationContext(
                                workingDirectory: workingDirectory
                                    ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                            )
                        )
                        try writeJSON(
                            InvocationResponse(
                                ok: true,
                                output: output,
                                error: nil
                            )
                        )
                    case .usage:
                        throw GeneratedFeatureError.usage
                    }
                } catch {
                    try? writeJSON(
                        InvocationResponse(
                            ok: false,
                            output: nil,
                            error: error.localizedDescription
                        )
                    )
                    exit(1)
                }
            }

            static func invoke(
                toolName: String,
                inputData: Data,
                context: InvocationContext
            ) throws -> String {
                guard toolName == generatedToolName else {
                    throw GeneratedFeatureError.unknownTool(toolName)
                }

                let normalizedInput = inputData.isEmpty ? Data("{}".utf8) : inputData
                let input = try JSONDecoder().decode(EchoInput.self, from: normalizedInput)

                _ = context
                return input.text ?? ""
            }

            static func writeJSON<T: Encodable>(_ value: T) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(value)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }

        private enum Command {
            case listTools
            case invoke(String, URL?)
            case usage
        }

        private struct ParsedArguments {
            let command: Command

            init(arguments: [String]) {
                guard let first = arguments.first else {
                    command = .usage
                    return
                }

                switch first {
                case "--list-tools":
                    command = .listTools
                case "--invoke":
                    guard arguments.count >= 2 else {
                        command = .usage
                        return
                    }
                    command = .invoke(
                        arguments[1],
                        Self.optionValue("--working-directory", in: arguments).map {
                            URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                        }
                    )
                default:
                    command = .usage
                }
            }

            static func optionValue(_ option: String, in arguments: [String]) -> String? {
                guard let index = arguments.firstIndex(of: option),
                      arguments.indices.contains(index + 1) else {
                    return nil
                }
                return arguments[index + 1]
            }
        }

        private enum GeneratedFeatureError: LocalizedError {
            case unknownTool(String)
            case usage

            var errorDescription: String? {
                switch self {
                case let .unknownTool(toolName):
                    return "Unknown feature tool: \(toolName)"
                case .usage:
                    return "Usage: feature-binary --list-tools | --invoke <tool-name> [--working-directory <path>]"
                }
            }
        }
        """#
    }

    static func mcpBridgeMainContents(
        serviceName: String,
        toolPrefix: String,
        endpointURLString: String?,
        executablePath: String?,
        arguments: [String],
        environment: [String: String]
    ) -> String {
        let escapedServiceName = swiftStringLiteral(serviceName)
        let escapedToolPrefix = swiftStringLiteral(toolPrefix)
        let endpointLiteral = endpointURLString.map(swiftStringLiteral) ?? "nil"
        let executablePathLiteral = executablePath.map(swiftStringLiteral) ?? "nil"
        let argumentsLiteral = swiftStringArrayLiteral(arguments)
        let environmentLiteral = swiftStringDictionaryLiteral(environment)
        return #"""
        import Foundation
        import MLXCoderCore
        import MLXFeatureKit
        #if canImport(Darwin)
        import Darwin
        #elseif canImport(Glibc)
        import Glibc
        #endif

        private let bridgeServiceName = \#(escapedServiceName)
        private let bridgeToolNamePrefix = \#(escapedToolPrefix)
        private let bridgeEndpointURLString: String? = \#(endpointLiteral)
        private let bridgeExecutablePath: String? = \#(executablePathLiteral)
        private let bridgeExecutableArguments: [String] = \#(argumentsLiteral)
        private let bridgeEnvironment: [String: String] = \#(environmentLiteral)

        @main
        enum MCPBridgeFeatureMain {
            static func main() async {
                let command = ParsedFeatureCommand(arguments: Array(CommandLine.arguments.dropFirst()))

                do {
                    switch command {
                    case .listTools:
                        let tools = try await listTools()
                        try emitJSON(ListToolsResponse(tools: tools))
                    case let .invoke(toolName):
                        let inputData = FileHandle.standardInput.readDataToEndOfFile()
                        let output = try await invoke(
                            toolName: toolName,
                            inputData: inputData
                        )
                        try emitJSON(
                            InvocationResponse(
                                ok: true,
                                output: .string(output),
                                error: nil
                            )
                        )
                    case .usage:
                        throw MCPBridgeFeatureError.usage
                    }
                } catch {
                    try? emitJSON(
                        InvocationResponse(
                            ok: false,
                            output: nil,
                            error: error.localizedDescription
                        )
                    )
                    terminate(code: 1)
                }
            }

            static func listTools() async throws -> [MLXFeatureToolDescriptor] {
                let executor = RemoteMCPToolExecutor(
                    configuration: try configuration(),
                    toolNamePrefix: bridgeToolNamePrefix
                )
                do {
                    let tools = try await executor.loadTools()
                    await executor.disconnect()
                    return ToolDescriptor.canonicalized(tools).map { tool in
                        MLXFeatureToolDescriptor(
                            name: tool.name,
                            description: tool.description.hasPrefix("\(bridgeServiceName):")
                                ? tool.description
                                : "\(bridgeServiceName): \(tool.description)",
                            inputSchema: tool.inputSchema,
                            outputSchema: tool.outputSchema
                        )
                    }
                } catch {
                    await executor.disconnect()
                    throw error
                }
            }

            static func invoke(
                toolName: String,
                inputData: Data
            ) async throws -> String {
                let executor = RemoteMCPToolExecutor(
                    configuration: try configuration(),
                    toolNamePrefix: bridgeToolNamePrefix
                )
                do {
                    let output = try await executor.execute(
                        ToolRequest(
                            name: toolName,
                            arguments: try decodeArguments(from: inputData)
                        )
                    )
                    await executor.disconnect()
                    return output.text
                } catch {
                    await executor.disconnect()
                    throw error
                }
            }

            static func configuration() throws -> MCPServerConfiguration {
                if let rawEndpointURL = bridgeEndpointURLString,
                   let endpointURL = URL(string: rawEndpointURL) {
                    return MCPServerConfiguration(
                        executablePath: "",
                        arguments: [],
                        environment: [:],
                        endpointURL: endpointURL
                    )
                }

                if let executablePath = bridgeExecutablePath,
                   !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var environment = ProcessInfo.processInfo.environment
                    environment.merge(bridgeEnvironment) { _, new in new }
                    return MCPServerConfiguration(
                        executablePath: executablePath,
                        arguments: bridgeExecutableArguments,
                        environment: environment
                    )
                }

                throw MCPBridgeFeatureError.unconfigured
            }

            static func decodeArguments(from data: Data) throws -> [String: JSONValue] {
                guard !data.isEmpty else {
                    return [:]
                }

                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                guard case let .object(arguments) = value else {
                    throw MCPBridgeFeatureError.invalidArguments
                }
                return arguments
            }

            static func emitJSON<T: Encodable>(_ value: T) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(value)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }

            static func terminate(code: Int32) -> Never {
                #if canImport(Darwin) || canImport(Glibc)
                exit(code)
                #else
                fatalError("MCP bridge feature terminated with code \(code).")
                #endif
            }
        }

        private struct ListToolsResponse: Encodable {
            let tools: [MLXFeatureToolDescriptor]
        }

        private struct InvocationResponse: Encodable {
            let ok: Bool
            let output: JSONValue?
            let error: String?
        }

        private enum ParsedFeatureCommand {
            case listTools
            case invoke(String)
            case usage

            init(arguments: [String]) {
                guard let first = arguments.first else {
                    self = .usage
                    return
                }

                switch first {
                case "--list-tools":
                    self = .listTools
                case "--invoke":
                    guard arguments.count >= 2 else {
                        self = .usage
                        return
                    }
                    self = .invoke(arguments[1])
                default:
                    self = .usage
                }
            }
        }

        private enum MCPBridgeFeatureError: LocalizedError {
            case invalidArguments
            case unconfigured
            case usage

            var errorDescription: String? {
                switch self {
                case .invalidArguments:
                    return "Expected a JSON object as tool arguments."
                case .unconfigured:
                    return "\(bridgeServiceName) MCP bridge is not configured. Set endpointURL for HTTP MCP or executablePath for stdio MCP in the scaffold arguments."
                case .usage:
                    return "Usage: feature-binary --list-tools | --invoke <tool-name> [--working-directory <path>]"
                }
            }
        }
        """#
    }

    static func featureManifestContents(
        id: String,
        displayName: String,
        description: String,
        toolName: String,
        enabled: Bool
    ) throws -> String {
        let object: [String: Any] = [
            "schemaVersion": SwiftFeatureManifest.currentSchemaVersion,
            "id": id,
            "displayName": displayName,
            "description": description,
            "enabled": enabled,
            "executable": ".build/release/\(id)",
            "toolNamePrefixes": [toolNamePrefix(from: toolName)],
            "build": [
                "system": "swiftpm",
                "packagePath": ".",
                "product": id,
                "configuration": "release",
                "executablePath": ".build/release/\(id)"
            ],
            "generated": [
                "by": "mlx-coder",
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ],
            "tools": [
                [
                    "name": toolName,
                    "description": "Echoes the provided text. Replace this implementation with the generated feature logic.",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "text": [
                                "type": "string"
                            ]
                        ],
                        "required": ["text"]
                    ]
                ]
            ]
        ]
        let data = try JSONValue(jsonObject: object).jsonData(
            outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func mcpBridgeFeatureManifestContents(
        id: String,
        displayName: String,
        description: String,
        toolPrefix: String,
        enabled: Bool
    ) throws -> String {
        let object: [String: Any] = [
            "schemaVersion": SwiftFeatureManifest.currentSchemaVersion,
            "id": id,
            "displayName": displayName,
            "description": description,
            "enabled": enabled,
            "executable": ".build/release/\(id)",
            "discoversToolsAtRuntime": true,
            "toolNamePrefixes": [toolPrefix],
            "toolNameAliases": [],
            "build": [
                "system": "swiftpm",
                "packagePath": ".",
                "product": id,
                "configuration": "release",
                "executablePath": ".build/release/\(id)"
            ],
            "generated": [
                "by": "mlx-coder",
                "createdAt": ISO8601DateFormatter().string(from: Date())
            ],
            "tools": []
        ]
        let data = try JSONValue(jsonObject: object).jsonData(
            outputFormatting: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func toolNamePrefix(from toolName: String) -> String {
        guard let dotIndex = toolName.lastIndex(of: ".") else {
            return "\(toolName)."
        }
        return String(toolName[...dotIndex])
    }

    static func swiftStringArrayLiteral(_ values: [String]) -> String {
        let renderedValues = values
            .map(swiftStringLiteral)
            .joined(separator: ", ")
        return "[\(renderedValues)]"
    }

    static func swiftStringDictionaryLiteral(_ values: [String: String]) -> String {
        guard !values.isEmpty else {
            return "[:]"
        }
        let renderedValues = values
            .sorted { $0.key < $1.key }
            .map { "\(swiftStringLiteral($0.key)): \(swiftStringLiteral($0.value))" }
            .joined(separator: ", ")
        return "[\(renderedValues)]"
    }

    static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

}
