//
//  SwiftFeatureToolRuntime.swift
//  MLXCoder
//

import Foundation

public enum SwiftFeatureBundleSource: String, Codable, Hashable, Sendable {
    case bundled
    case generated
}

public struct SwiftFeatureBundle: Hashable, Sendable {
    public let id: String
    public let executableURL: URL
    public let tools: [ToolDescriptor]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let source: SwiftFeatureBundleSource

    public init(
        id: String,
        executableURL: URL,
        tools: [ToolDescriptor],
        toolNamePrefixes: [String] = [],
        toolNameAliases: [String] = [],
        discoversToolsAtRuntime: Bool = false,
        source: SwiftFeatureBundleSource = .generated
    ) {
        self.id = id.nilIfBlank ?? executableURL.lastPathComponent
        self.executableURL = executableURL.standardizedFileURL
        self.tools = ToolDescriptor.canonicalized(tools)
        self.toolNamePrefixes = toolNamePrefixes
        self.toolNameAliases = toolNameAliases
        self.discoversToolsAtRuntime = discoversToolsAtRuntime
        self.source = source
    }

    public func contains(toolName: String) -> Bool {
        tools.contains { $0.name == toolName }
            || toolNameAliases.contains(toolName)
            || toolNamePrefixes.contains { toolName.hasPrefix($0) }
    }

    public func isRelevant(allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }

        guard !allowedToolNames.isEmpty else {
            return false
        }

        if tools.contains(where: { DirectToolExecutor.isAllowed($0.name, allowedToolNames: allowedToolNames) }) {
            return true
        }

        if toolNameAliases.contains(where: { DirectToolExecutor.isAllowed($0, allowedToolNames: allowedToolNames) }) {
            return true
        }

        for prefix in toolNamePrefixes {
            if allowedToolNames.contains(prefix) {
                return true
            }
            if allowedToolNames.contains(where: { allowedToolName in
                allowedToolName.hasPrefix(prefix) || prefix.hasPrefix(allowedToolName)
            }) {
                return true
            }
        }

        if allowedToolNames.contains(SwiftFeatureRuntime.featurePackageToolsAllowedName) {
            return true
        }

        return false
    }
}

public struct SwiftFeatureManifest: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let displayName: String?
    public let description: String?
    public let executable: String
    public let enabled: Bool
    public let tools: [SwiftFeatureToolManifest]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case schema_version
        case id
        case name
        case displayName
        case display_name
        case description
        case executable
        case binary
        case enabled
        case tools
        case toolNamePrefixes
        case tool_name_prefixes
        case toolNameAliases
        case tool_name_aliases
        case discoversToolsAtRuntime
        case discovers_tools_at_runtime
        case build
        case generated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .schema_version)
            ?? Self.currentSchemaVersion
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try Self.firstString(
            in: container,
            keys: [.displayName, .display_name, .name]
        )?.nilIfBlank
        self.description = try container.decodeIfPresent(String.self, forKey: .description)?.nilIfBlank
        self.executable = try container.decodeIfPresent(String.self, forKey: .executable)
            ?? container.decode(String.self, forKey: .binary)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.tools = try container.decode([SwiftFeatureToolManifest].self, forKey: .tools)
        self.toolNamePrefixes = try Self.stringArray(
            in: container,
            keys: [.toolNamePrefixes, .tool_name_prefixes]
        )
        self.toolNameAliases = try Self.stringArray(
            in: container,
            keys: [.toolNameAliases, .tool_name_aliases]
        )
        self.discoversToolsAtRuntime = try container.decodeIfPresent(
            Bool.self,
            forKey: .discoversToolsAtRuntime
        ) ?? container.decodeIfPresent(
            Bool.self,
            forKey: .discovers_tools_at_runtime
        ) ?? false
        self.build = try container.decodeIfPresent(SwiftFeatureBuildManifest.self, forKey: .build)
        self.generated = try container.decodeIfPresent(SwiftFeatureGeneratedManifest.self, forKey: .generated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(executable, forKey: .executable)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(tools, forKey: .tools)
        if !toolNamePrefixes.isEmpty {
            try container.encode(toolNamePrefixes, forKey: .toolNamePrefixes)
        }
        if !toolNameAliases.isEmpty {
            try container.encode(toolNameAliases, forKey: .toolNameAliases)
        }
        if discoversToolsAtRuntime {
            try container.encode(discoversToolsAtRuntime, forKey: .discoversToolsAtRuntime)
        }
        try container.encodeIfPresent(build, forKey: .build)
        try container.encodeIfPresent(generated, forKey: .generated)
    }

    private static func firstString(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String? {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func stringArray(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> [String] {
        for key in keys {
            if let values = try container.decodeIfPresent([String].self, forKey: key) {
                return normalizedStrings(values)
            }
        }
        return []
    }

    private static func normalizedStrings(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { $0.nilIfBlank })).sorted()
    }
}

public struct SwiftFeatureBuildManifest: Codable, Sendable {
    public let system: String
    public let packagePath: String?
    public let product: String?
    public let configuration: String?
    public let executablePath: String?
    public let arguments: [String]

    private enum CodingKeys: String, CodingKey {
        case system
        case packagePath
        case package_path
        case product
        case configuration
        case executablePath
        case executable_path
        case arguments
    }

    public init(
        system: String = "swiftpm",
        packagePath: String? = nil,
        product: String? = nil,
        configuration: String? = "release",
        executablePath: String? = nil,
        arguments: [String] = []
    ) {
        self.system = system.nilIfBlank ?? "swiftpm"
        self.packagePath = packagePath?.nilIfBlank
        self.product = product?.nilIfBlank
        self.configuration = configuration?.nilIfBlank
        self.executablePath = executablePath?.nilIfBlank
        self.arguments = arguments.compactMap { $0.nilIfBlank }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            system: try container.decodeIfPresent(String.self, forKey: .system) ?? "swiftpm",
            packagePath: try container.decodeIfPresent(String.self, forKey: .packagePath)
                ?? container.decodeIfPresent(String.self, forKey: .package_path),
            product: try container.decodeIfPresent(String.self, forKey: .product),
            configuration: try container.decodeIfPresent(String.self, forKey: .configuration) ?? "release",
            executablePath: try container.decodeIfPresent(String.self, forKey: .executablePath)
                ?? container.decodeIfPresent(String.self, forKey: .executable_path),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(system, forKey: .system)
        try container.encodeIfPresent(packagePath, forKey: .packagePath)
        try container.encodeIfPresent(product, forKey: .product)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(executablePath, forKey: .executablePath)
        if !arguments.isEmpty {
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

public struct SwiftFeatureGeneratedManifest: Codable, Sendable {
    public let by: String?
    public let prompt: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case by
        case prompt
        case createdAt
        case created_at
    }

    public init(
        by: String? = nil,
        prompt: String? = nil,
        createdAt: String? = nil
    ) {
        self.by = by?.nilIfBlank
        self.prompt = prompt?.nilIfBlank
        self.createdAt = createdAt?.nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            by: try container.decodeIfPresent(String.self, forKey: .by),
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt),
            createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt)
                ?? container.decodeIfPresent(String.self, forKey: .created_at)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(by, forKey: .by)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

public struct SwiftFeatureToolManifest: Codable, Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case input_schema
        case outputSchema
        case output_schema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfBlank
        self.description = try container.decode(String.self, forKey: .description)
        self.inputSchema = try Self.schemaString(
            for: container,
            primaryKey: .inputSchema,
            alternateKey: .input_schema
        ) ?? "{}"
        self.outputSchema = try Self.schemaString(
            for: container,
            primaryKey: .outputSchema,
            alternateKey: .output_schema
        )?.nilIfBlank
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
    }

    public var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
    }

    private static func schemaString(
        for container: KeyedDecodingContainer<CodingKeys>,
        primaryKey: CodingKeys,
        alternateKey: CodingKeys
    ) throws -> String? {
        for key in [primaryKey, alternateKey] {
            if let value = try? container.decodeIfPresent(JSONValue.self, forKey: key) {
                switch value {
                case let .string(schema):
                    return schema
                default:
                    return value.prettyPrinted()
                }
            }
        }
        return nil
    }
}

public struct SwiftFeatureRecord: Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let source: SwiftFeatureBundleSource
    public let executableURL: URL
    public let manifestURL: URL?
    public let manifestEnabled: Bool
    public let executableAvailable: Bool
    public let tools: [ToolDescriptor]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?
    public let issue: String?

    public var enabled: Bool {
        manifestEnabled && executableAvailable
    }
}

public struct SwiftFeatureStatus: Codable, Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let source: SwiftFeatureBundleSource
    public let enabled: Bool
    public let available: Bool
    public let executablePath: String
    public let manifestPath: String?
    public let tools: [String]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let toolCount: Int
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?
    public let issue: String?

    public init(
        id: String,
        displayName: String?,
        description: String?,
        source: SwiftFeatureBundleSource,
        enabled: Bool,
        available: Bool,
        executablePath: String,
        manifestPath: String?,
        tools: [String],
        toolNamePrefixes: [String],
        toolNameAliases: [String],
        discoversToolsAtRuntime: Bool,
        build: SwiftFeatureBuildManifest?,
        generated: SwiftFeatureGeneratedManifest?,
        issue: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.source = source
        self.enabled = enabled
        self.available = available
        self.executablePath = executablePath
        self.manifestPath = manifestPath
        self.tools = tools
        self.toolNamePrefixes = toolNamePrefixes
        self.toolNameAliases = toolNameAliases
        self.discoversToolsAtRuntime = discoversToolsAtRuntime
        self.toolCount = tools.count
        self.build = build
        self.generated = generated
        self.issue = issue
    }
}

public struct SwiftFeatureValidationReport: Codable, Sendable {
    public let ok: Bool
    public let id: String?
    public let manifestPath: String
    public let executablePath: String?
    public let errors: [String]
    public let warnings: [String]
    public let tools: [String]

    public init(
        id: String?,
        manifestPath: String,
        executablePath: String?,
        errors: [String],
        warnings: [String],
        tools: [String]
    ) {
        self.ok = errors.isEmpty
        self.id = id
        self.manifestPath = manifestPath
        self.executablePath = executablePath
        self.errors = errors
        self.warnings = warnings
        self.tools = tools
    }
}

public struct SwiftFeatureBuildReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let command: [String]
    public let workingDirectory: String
    public let executablePath: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
}

public struct SwiftFeatureScaffoldReport: Codable, Sendable {
    public let id: String
    public let directoryPath: String
    public let manifestPath: String
    public let packagePath: String
    public let sourcePath: String
    public let toolName: String
}

public struct SwiftFeatureInstallReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let sourcePath: String
    public let destinationPath: String
    public let manifestPath: String
    public let copied: Bool
    public let built: Bool
    public let enabled: Bool
    public let validation: SwiftFeatureValidationReport
    public let build: SwiftFeatureBuildReport?
}

public struct SwiftFeatureDeleteReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let directoryPath: String
    public let manifestPath: String
    public let removed: Bool
    public let wasEnabled: Bool
}

public struct SwiftFeatureState: Codable, Sendable {
    public static let currentVersion = 1
    public static let defaultDisabledBundledFeatureIDs: Set<String> = [
        "mlx-jira-tools"
    ]

    public var version: Int
    public var disabledBundledFeatureIDs: [String]
    public var enabledBundledFeatureIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case version
        case disabledBundledFeatureIDs
        case enabledBundledFeatureIDs
    }

    public init(
        version: Int = Self.currentVersion,
        disabledBundledFeatureIDs: [String] = [],
        enabledBundledFeatureIDs: [String] = []
    ) {
        self.version = version
        self.disabledBundledFeatureIDs = Array(
            Set(disabledBundledFeatureIDs.compactMap { $0.nilIfBlank })
        ).sorted()
        self.enabledBundledFeatureIDs = Array(
            Set(enabledBundledFeatureIDs.compactMap { $0.nilIfBlank })
        ).sorted()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
            disabledBundledFeatureIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .disabledBundledFeatureIDs
            ) ?? [],
            enabledBundledFeatureIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .enabledBundledFeatureIDs
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(disabledBundledFeatureIDs, forKey: .disabledBundledFeatureIDs)
        try container.encode(enabledBundledFeatureIDs, forKey: .enabledBundledFeatureIDs)
    }

    public func bundledFeatureIsEnabled(id: String) -> Bool {
        guard !disabledBundledFeatureIDs.contains(id) else {
            return false
        }
        if Self.defaultDisabledBundledFeatureIDs.contains(id) {
            return enabledBundledFeatureIDs.contains(id)
        }
        return true
    }
}

public enum SwiftFeatureStateStore {
    public static let stateFilename = "feature-state.json"

    public static func stateURL(fileManager: FileManager = .default) -> URL {
        MLXAppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(stateFilename)
            .standardizedFileURL
    }

    public static func load(
        fileManager: FileManager = .default
    ) -> SwiftFeatureState {
        let url = stateURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SwiftFeatureState.self, from: data) else {
            return SwiftFeatureState()
        }
        return SwiftFeatureState(
            version: SwiftFeatureState.currentVersion,
            disabledBundledFeatureIDs: state.disabledBundledFeatureIDs,
            enabledBundledFeatureIDs: state.enabledBundledFeatureIDs
        )
    }

    public static func setBundledFeature(
        id rawID: String,
        enabled: Bool,
        fileManager: FileManager = .default
    ) throws {
        guard let id = rawID.nilIfBlank else {
            throw DirectToolError.missingArgument("id")
        }

        let state = load(fileManager: fileManager)
        var disabledIDs = Set(state.disabledBundledFeatureIDs)
        var enabledIDs = Set(state.enabledBundledFeatureIDs)
        if SwiftFeatureState.defaultDisabledBundledFeatureIDs.contains(id) {
            if enabled {
                enabledIDs.insert(id)
                disabledIDs.remove(id)
            } else {
                enabledIDs.remove(id)
                disabledIDs.insert(id)
            }
        } else if enabled {
            disabledIDs.remove(id)
            enabledIDs.remove(id)
        } else {
            disabledIDs.insert(id)
            enabledIDs.remove(id)
        }
        try save(
            SwiftFeatureState(
                disabledBundledFeatureIDs: Array(disabledIDs),
                enabledBundledFeatureIDs: Array(enabledIDs)
            ),
            fileManager: fileManager
        )
    }

    private static func save(
        _ state: SwiftFeatureState,
        fileManager: FileManager
    ) throws {
        let url = stateURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(state).write(to: url, options: [.atomic])
    }
}

public enum SwiftFeatureRegistry {
    public static let manifestFilename = "feature.json"

    public static func appFeatureRootURL(
        fileManager: FileManager = .default
    ) -> URL {
        MLXAppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("features", isDirectory: true)
            .standardizedFileURL
    }

    public static func discoverFeatureBundles(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureBundle] {
        discoverFeatureRecords(searchRoots: searchRoots, fileManager: fileManager)
            .compactMap { record in
                guard record.enabled else {
                    return nil
                }
                return SwiftFeatureBundle(
                    id: record.id,
                    executableURL: record.executableURL,
                    tools: record.tools,
                    toolNamePrefixes: record.toolNamePrefixes,
                    toolNameAliases: record.toolNameAliases,
                    discoversToolsAtRuntime: record.discoversToolsAtRuntime,
                    source: .generated
                )
            }
    }

    public static func discoverFeatureRecords(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureRecord] {
        let roots = searchRoots ?? [appFeatureRootURL(fileManager: fileManager)]
        return roots.flatMap { root in
            discoverFeatureRecords(
                under: root.standardizedFileURL,
                fileManager: fileManager
            )
        }.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func discoverFeatureRecords(
        under rootURL: URL,
        fileManager: FileManager
    ) -> [SwiftFeatureRecord] {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var records: [SwiftFeatureRecord] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent == manifestFilename,
                  let record = featureRecord(
                      manifestURL: url.standardizedFileURL,
                      fileManager: fileManager
                  ) else {
                continue
            }
            records.append(record)
        }
        return records
    }

    public static func featureRecord(
        manifestURL: URL,
        fileManager: FileManager
    ) -> SwiftFeatureRecord? {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SwiftFeatureManifest.self, from: data) else {
            return nil
        }

        let executableURL = resolvedExecutableURL(
            manifest.executable,
            relativeTo: manifestURL.deletingLastPathComponent()
        )
        let executableAvailable = fileManager.isExecutableFile(atPath: executableURL.path)
        return SwiftFeatureRecord(
            id: manifest.id,
            displayName: manifest.displayName,
            description: manifest.description,
            source: .generated,
            executableURL: executableURL,
            manifestURL: manifestURL,
            manifestEnabled: manifest.enabled,
            executableAvailable: executableAvailable,
            tools: manifest.tools.map(\.toolDescriptor),
            toolNamePrefixes: manifest.toolNamePrefixes,
            toolNameAliases: manifest.toolNameAliases,
            discoversToolsAtRuntime: manifest.discoversToolsAtRuntime,
            build: manifest.build,
            generated: manifest.generated,
            issue: executableAvailable ? nil : "Executable not found or not executable."
        )
    }

    public static func featureRecord(
        id: String,
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> SwiftFeatureRecord? {
        discoverFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        ).first { $0.id == id }
    }

    public static func setFeatureManifestEnabled(
        manifestURL: URL,
        enabled: Bool,
        fileManager: FileManager = .default
    ) throws {
        let data = try Data(contentsOf: manifestURL)
        let object = try JSONSerialization.jsonObject(with: data)
        guard var dictionary = object as? [String: Any] else {
            throw DirectToolError.permissionDenied(
                "Feature manifest is not a JSON object: \(manifestURL.path)"
            )
        }
        dictionary["enabled"] = enabled
        let outputData = try JSONSerialization.data(
            withJSONObject: dictionary,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try fileManager.createDirectory(
            at: manifestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try outputData.write(to: manifestURL, options: [.atomic])
    }

    public static func resolvedExecutableURL(
        _ path: String,
        relativeTo directoryURL: URL
    ) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return directoryURL
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }
}

public actor SwiftFeatureRuntime {
    public static let featurePackageToolsAllowedName = "feature.tools"
    public static let generatedSwiftToolsVersion = "6.3"

    private struct BundledFeatureDefinition: Sendable {
        let id: String
        let executableName: String
        let tools: [ToolDescriptor]
        let toolNamePrefixes: [String]
        let toolNameAliases: [String]
        let discoversToolsAtRuntime: Bool

        init(
            id: String,
            executableName: String,
            tools: [ToolDescriptor],
            toolNamePrefixes: [String] = [],
            toolNameAliases: [String] = [],
            discoversToolsAtRuntime: Bool = false
        ) {
            self.id = id
            self.executableName = executableName
            self.tools = ToolDescriptor.canonicalized(tools)
            self.toolNamePrefixes = toolNamePrefixes
            self.toolNameAliases = toolNameAliases
            self.discoversToolsAtRuntime = discoversToolsAtRuntime
        }

        func bundle(executableURL: URL) -> SwiftFeatureBundle {
            SwiftFeatureBundle(
                id: id,
                executableURL: executableURL,
                tools: tools,
                toolNamePrefixes: toolNamePrefixes,
                toolNameAliases: toolNameAliases,
                discoversToolsAtRuntime: discoversToolsAtRuntime,
                source: .bundled
            )
        }
    }

    public static func isFeatureManagementToolName(_ toolName: String) -> Bool {
        switch toolName {
        case "feature.list",
             "feature.enable",
             "feature.disable",
             "feature.delete",
             "feature.reload",
             "feature.validate",
             "feature.build",
             "feature.scaffold",
             "feature.install":
            return true
        default:
            return false
        }
    }

    private let explicitFeatures: [SwiftFeatureBundle]?
    private let featureSearchRoots: [URL]?
    private let fileManager: FileManager
    private var features: [SwiftFeatureBundle]
    private var runtimeDiscoveredToolsByFeatureID: [String: [ToolDescriptor]] = [:]

    public init(
        features explicitFeatures: [SwiftFeatureBundle]? = nil,
        featureSearchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.explicitFeatures = explicitFeatures
        self.featureSearchRoots = featureSearchRoots
        self.fileManager = fileManager
        if let explicitFeatures {
            self.features = explicitFeatures
        } else {
            self.features = Self.defaultFeatureBundles(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
        }
    }

    public func descriptors(
        allowedToolNames: Set<String>? = nil
    ) async -> [DirectToolDescriptor] {
        var resolvedTools: [ToolDescriptor] = []
        for feature in features where feature.isRelevant(allowedToolNames: allowedToolNames) {
            if allowedToolNames == nil, feature.discoversToolsAtRuntime {
                resolvedTools.append(contentsOf: feature.tools)
            } else {
                resolvedTools.append(contentsOf: await tools(for: feature))
            }
        }

        return ToolDescriptor.canonicalized(resolvedTools).map {
            DirectToolDescriptor(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }

    public func featureToolIsAllowed(
        toolName: String,
        allowedToolNames: Set<String>?
    ) -> Bool {
        guard let feature = features.first(where: { $0.contains(toolName: toolName) }) else {
            return false
        }
        return feature.isRelevant(allowedToolNames: allowedToolNames)
    }

    public func canExecute(toolName: String) -> Bool {
        features.contains { $0.contains(toolName: toolName) }
    }

    public func executeIfAvailable(
        toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) async throws -> String? {
        guard let feature = features.first(where: { $0.contains(toolName: toolCall.name) }) else {
            return nil
        }

        let result = try await AsyncProcessRunner.run(
            executableURL: feature.executableURL,
            arguments: [
                "--invoke",
                toolCall.name,
                "--working-directory",
                workingDirectory.path
            ],
            workingDirectory: workingDirectory,
            environment: DeveloperToolEnvironment.processEnvironment(),
            stdinData: Data(toolCall.argumentsJSON.utf8),
            timeout: 60
        )
        return try Self.renderInvocationResult(result, feature: feature)
    }

    public func featureStatuses(
        includeTools: Bool = true,
        includeDisabled: Bool = true,
        discoverRuntimeTools: Bool = false
    ) async -> [SwiftFeatureStatus] {
        var statuses = explicitFeatures == nil
            ? Self.defaultFeatureRecords(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            ).map { Self.status(from: $0, tools: includeTools ? $0.tools.map(\.name) : []) }
            : features.map {
                Self.status(
                    from: $0,
                    enabled: true,
                    available: fileManager.isExecutableFile(atPath: $0.executableURL.path),
                    manifestPath: nil,
                    issue: nil,
                    tools: includeTools ? $0.tools.map(\.name) : []
                )
            }

        if includeTools && discoverRuntimeTools {
            for feature in features {
                let tools = await tools(for: feature).map(\.name)
                guard let index = statuses.firstIndex(where: { $0.id == feature.id }) else {
                    continue
                }
                let current = statuses[index]
                statuses[index] = SwiftFeatureStatus(
                    id: current.id,
                    displayName: current.displayName,
                    description: current.description,
                    source: current.source,
                    enabled: current.enabled,
                    available: current.available,
                    executablePath: current.executablePath,
                    manifestPath: current.manifestPath,
                    tools: tools,
                    toolNamePrefixes: current.toolNamePrefixes,
                    toolNameAliases: current.toolNameAliases,
                    discoversToolsAtRuntime: current.discoversToolsAtRuntime,
                    build: current.build,
                    generated: current.generated,
                    issue: current.issue
                )
            }
        }

        if !includeDisabled {
            statuses = statuses.filter(\.enabled)
        }
        return statuses.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    public func executeManagementTool(
        toolCall: DirectAgentToolCall
    ) async throws -> String {
        let arguments = toolCall.argumentsObject
        switch toolCall.name {
        case "feature.list":
            let includeTools = arguments.bool("includeTools", "include_tools") ?? true
            let includeDisabled = arguments.bool("includeDisabled", "include_disabled") ?? true
            let discoverRuntimeTools = arguments.bool("discoverRuntimeTools", "discover_runtime_tools") ?? false
            return try await renderFeatureList(
                includeTools: includeTools,
                includeDisabled: includeDisabled,
                discoverRuntimeTools: discoverRuntimeTools
            )
        case "feature.enable":
            let id = try Self.requiredFeatureID(arguments)
            try await setFeature(id: id, enabled: true)
            return try await renderFeatureMutation(
                action: "enabled",
                id: id
            )
        case "feature.disable":
            let id = try Self.requiredFeatureID(arguments)
            try await setFeature(id: id, enabled: false)
            return try await renderFeatureMutation(
                action: "disabled",
                id: id
            )
        case "feature.delete":
            let report = try await deleteFeature(arguments: arguments)
            reloadFeatureBundles()
            return try renderJSON(report)
        case "feature.reload":
            reloadFeatureBundles()
            return try await renderFeatureList(
                prefix: "Reloaded Swift features.",
                includeTools: arguments.bool("includeTools", "include_tools") ?? true,
                includeDisabled: arguments.bool("includeDisabled", "include_disabled") ?? true,
                discoverRuntimeTools: arguments.bool("discoverRuntimeTools", "discover_runtime_tools") ?? false
            )
        case "feature.validate":
            return try renderJSON(
                validateFeature(arguments: arguments)
            )
        case "feature.build":
            let report = try await buildFeature(arguments: arguments)
            if report.ok {
                reloadFeatureBundles()
            }
            return try renderJSON(report)
        case "feature.scaffold":
            return try renderJSON(
                scaffoldFeature(arguments: arguments)
            )
        case "feature.install":
            let report = try await installFeature(arguments: arguments)
            if report.ok {
                reloadFeatureBundles()
            }
            return try renderJSON(report)
        default:
            throw DirectToolError.unknownTool(toolCall.name)
        }
    }

    private func setFeature(id: String, enabled: Bool) async throws {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature enable/disable is unavailable for an explicitly constructed runtime."
            )
        }

        let bundledIDs = Set(Self.bundledFeatureDefinitions().map(\.id))
        if bundledIDs.contains(id) {
            try SwiftFeatureStateStore.setBundledFeature(
                id: id,
                enabled: enabled,
                fileManager: fileManager
            )
            reloadFeatureBundles()
            return
        }

        guard let record = SwiftFeatureRegistry
            .discoverFeatureRecords(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
            .first(where: { $0.id == id }),
            let manifestURL = record.manifestURL else {
            throw DirectToolError.permissionDenied("Unknown Swift feature: \(id).")
        }

        try SwiftFeatureRegistry.setFeatureManifestEnabled(
            manifestURL: manifestURL,
            enabled: enabled,
            fileManager: fileManager
        )
        reloadFeatureBundles()
    }

    private func validateFeature(
        arguments: [String: Any]
    ) throws -> SwiftFeatureValidationReport {
        let manifestURL = try featureManifestURL(arguments: arguments)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return SwiftFeatureValidationReport(
                id: arguments.string("id", "featureID", "feature_id", "name"),
                manifestPath: manifestURL.path,
                executablePath: nil,
                errors: ["Feature manifest not found: \(manifestURL.path)"],
                warnings: [],
                tools: []
            )
        }

        let data = try Data(contentsOf: manifestURL)
        let manifest: SwiftFeatureManifest
        do {
            manifest = try JSONDecoder().decode(SwiftFeatureManifest.self, from: data)
        } catch {
            return SwiftFeatureValidationReport(
                id: nil,
                manifestPath: manifestURL.path,
                executablePath: nil,
                errors: ["Invalid feature manifest: \(error.localizedDescription)"],
                warnings: [],
                tools: []
            )
        }

        var errors: [String] = []
        var warnings: [String] = []
        let featureDirectoryURL = manifestURL.deletingLastPathComponent()
        let executableURL = SwiftFeatureRegistry.resolvedExecutableURL(
            manifest.executable,
            relativeTo: featureDirectoryURL
        )
        let toolNames = manifest.tools.map(\.name)

        if !Self.isValidFeatureID(manifest.id) {
            errors.append("Feature id '\(manifest.id)' is invalid. Use letters, numbers, dots, underscores, and hyphens.")
        }
        if manifest.schemaVersion > SwiftFeatureManifest.currentSchemaVersion {
            errors.append("Unsupported feature schemaVersion \(manifest.schemaVersion). Current supported version is \(SwiftFeatureManifest.currentSchemaVersion).")
        }
        if manifest.enabled,
           !fileManager.isExecutableFile(atPath: executableURL.path) {
            errors.append("Executable is missing or not executable: \(executableURL.path)")
        } else if !fileManager.fileExists(atPath: executableURL.path) {
            warnings.append("Executable has not been built yet: \(executableURL.path)")
        }
        if manifest.tools.isEmpty,
           !manifest.discoversToolsAtRuntime {
            errors.append("Feature must declare at least one tool or set discoversToolsAtRuntime=true.")
        }
        if manifest.discoversToolsAtRuntime,
           manifest.toolNamePrefixes.isEmpty,
           manifest.toolNameAliases.isEmpty,
           manifest.tools.isEmpty {
            warnings.append("Runtime-discovered feature has no toolNamePrefixes or toolNameAliases; declare a prefix or alias so it can be selected explicitly.")
        }

        errors.append(contentsOf: Self.validationErrorsForToolNames(toolNames))

        if let build = manifest.build {
            if build.system.lowercased() != "swiftpm" {
                errors.append("Unsupported build system '\(build.system)'. Only swiftpm is currently supported.")
            }
            let packageDirectoryURL = Self.resolveBuildPackageDirectory(
                build: build,
                featureDirectoryURL: featureDirectoryURL
            )
            errors.append(contentsOf: Self.validatePackageSwiftToolsVersion(
                packageDirectoryURL: packageDirectoryURL
            ))
        }

        return SwiftFeatureValidationReport(
            id: manifest.id,
            manifestPath: manifestURL.path,
            executablePath: executableURL.path,
            errors: errors,
            warnings: warnings,
            tools: toolNames.sorted()
        )
    }

    private func buildFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureBuildReport {
        let manifestURL = try featureManifestURL(arguments: arguments)
        guard let record = SwiftFeatureRegistry.featureRecord(
            manifestURL: manifestURL,
            fileManager: fileManager
        ) else {
            throw DirectToolError.permissionDenied(
                "Feature manifest is missing or invalid: \(manifestURL.path)"
            )
        }

        let validationReport = try validateFeature(
            arguments: ["manifestPath": manifestURL.path]
        )
        let blockingErrors = validationReport.errors.filter {
            !$0.hasPrefix("Executable is missing or not executable:")
        }
        guard blockingErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                "Feature validation failed before build:\n\(blockingErrors.joined(separator: "\n"))"
            )
        }

        let build = record.build ?? SwiftFeatureBuildManifest(
            product: record.id,
            configuration: "release",
            executablePath: record.executableURL.path
        )
        guard build.system.lowercased() == "swiftpm" else {
            throw DirectToolError.permissionDenied(
                "Unsupported build system '\(build.system)'. Only swiftpm is currently supported."
            )
        }

        let featureDirectoryURL = manifestURL.deletingLastPathComponent()
        let packageDirectoryURL = Self.resolveBuildPackageDirectory(
            build: build,
            featureDirectoryURL: featureDirectoryURL
        )
        let toolsVersionErrors = Self.validatePackageSwiftToolsVersion(
            packageDirectoryURL: packageDirectoryURL
        )
        guard toolsVersionErrors.isEmpty else {
            throw DirectToolError.permissionDenied(
                toolsVersionErrors.joined(separator: "\n")
            )
        }

        let configuration = build.configuration ?? "release"
        let product = build.product ?? record.id
        let commandArguments = [
            "build",
            "-c",
            configuration,
            "--product",
            product
        ] + build.arguments
        let timeout = TimeInterval(arguments.int("timeoutSeconds", "timeout") ?? 300)
        let result = try await AsyncProcessRunner.run(
            executableURL: Self.swiftExecutableURL(fileManager: fileManager),
            arguments: commandArguments,
            workingDirectory: packageDirectoryURL,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: timeout
        )
        let executableAvailable = fileManager.isExecutableFile(
            atPath: record.executableURL.path
        )

        return SwiftFeatureBuildReport(
            ok: result.exitCode == 0 && executableAvailable,
            id: record.id,
            command: ["swift"] + commandArguments,
            workingDirectory: packageDirectoryURL.path,
            executablePath: record.executableURL.path,
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stdout: result.stdout,
            stderr: executableAvailable
                ? result.stderr
                : result.stderr + "\nExecutable not found after build: \(record.executableURL.path)"
        )
    }

    private func scaffoldFeature(
        arguments: [String: Any]
    ) throws -> SwiftFeatureScaffoldReport {
        let id = try Self.requiredFeatureID(arguments)
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }

        let directoryURL = try scaffoldDirectoryURL(id: id, arguments: arguments)
        let manifestURL = directoryURL.appendingPathComponent(
            SwiftFeatureRegistry.manifestFilename
        )
        let overwrite = arguments.bool("overwrite") ?? false
        if fileManager.fileExists(atPath: manifestURL.path),
           !overwrite {
            throw DirectToolError.permissionDenied(
                "Feature already exists at \(directoryURL.path). Pass overwrite=true to replace scaffold files."
            )
        }

        let template = Self.scaffoldTemplate(arguments: arguments)
        let displayName = arguments.string("displayName", "display_name", "name")?.nilIfBlank ?? id
        let description = arguments.string("description")?.nilIfBlank
            ?? Self.defaultScaffoldDescription(template: template, displayName: displayName)
        let targetName = Self.targetName(for: id)
        let productName = id
        let sourceDirectoryURL = directoryURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
        let packageURL = directoryURL.appendingPathComponent("Package.swift")
        let sourceURL = sourceDirectoryURL.appendingPathComponent("main.swift")

        try fileManager.createDirectory(
            at: sourceDirectoryURL,
            withIntermediateDirectories: true
        )

        let reportToolName: String
        switch template {
        case .basic:
            let toolName = arguments
                .string("toolName", "tool_name")?
                .nilIfBlank ?? "\(Self.defaultToolPrefix(for: id)).echo"
            let toolErrors = Self.validationErrorsForToolNames([toolName])
            guard toolErrors.isEmpty else {
                throw DirectToolError.permissionDenied(toolErrors.joined(separator: "\n"))
            }
            try Self.packageManifestContents(
                productName: productName,
                targetName: targetName
            ).write(to: packageURL, atomically: true, encoding: .utf8)
            try Self.featureMainContents(
                toolName: toolName,
                toolDescription: "Echoes the provided text. Replace this implementation with the generated feature logic."
            ).write(to: sourceURL, atomically: true, encoding: .utf8)
            try Self.featureManifestContents(
                id: id,
                displayName: displayName,
                description: description,
                toolName: toolName,
                enabled: arguments.bool("enabled") ?? false
            ).write(to: manifestURL, atomically: true, encoding: .utf8)
            reportToolName = toolName
        case .mcpBridge:
            let toolPrefix = Self.normalizedToolPrefix(
                arguments.string("toolPrefix", "tool_prefix", "prefix")?
                    .nilIfBlank ?? "\(Self.defaultToolPrefix(for: id))."
            )
            try Self.validateMCPBridgeToolPrefix(toolPrefix)
            let packagePath = arguments
                .string("mlxServerPackagePath", "mlx_server_package_path", "dependencyPath", "dependency_path")?
                .nilIfBlank ?? Self.defaultMLXServerPackagePath(fileManager: fileManager)
            let serviceName = arguments
                .string("serviceName", "service_name")?
                .nilIfBlank ?? displayName
            try Self.mcpBridgePackageManifestContents(
                productName: productName,
                targetName: targetName,
                mlxServerPackagePath: packagePath
            ).write(to: packageURL, atomically: true, encoding: .utf8)
            try Self.mcpBridgeMainContents(
                serviceName: serviceName,
                toolPrefix: toolPrefix,
                endpointURLString: arguments.string("endpointURL", "endpoint_url", "url")?.nilIfBlank,
                executablePath: arguments.string("executablePath", "executable_path", "command")?.nilIfBlank,
                arguments: Self.stringArrayArgument(
                    arguments,
                    keys: ["arguments", "args", "commandArguments", "command_arguments"]
                ),
                environment: Self.stringDictionaryArgument(
                    arguments,
                    keys: ["environment", "env"]
                )
            ).write(to: sourceURL, atomically: true, encoding: .utf8)
            try Self.mcpBridgeFeatureManifestContents(
                id: id,
                displayName: displayName,
                description: description,
                toolPrefix: toolPrefix,
                enabled: arguments.bool("enabled") ?? false
            ).write(to: manifestURL, atomically: true, encoding: .utf8)
            reportToolName = toolPrefix
        }

        return SwiftFeatureScaffoldReport(
            id: id,
            directoryPath: directoryURL.path,
            manifestPath: manifestURL.path,
            packagePath: packageURL.path,
            sourcePath: sourceURL.path,
            toolName: reportToolName
        )
    }

    private func installFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureInstallReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature install is unavailable for an explicitly constructed runtime."
            )
        }

        let sourceManifestURL = try installSourceManifestURL(arguments: arguments)
        guard fileManager.fileExists(atPath: sourceManifestURL.path) else {
            throw DirectToolError.permissionDenied(
                "Feature manifest not found: \(sourceManifestURL.path)"
            )
        }
        let sourceDirectoryURL = sourceManifestURL.deletingLastPathComponent()
        let sourceManifest = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: Data(contentsOf: sourceManifestURL)
        )
        let id = arguments.string("id", "featureID", "feature_id", "name")?.nilIfBlank ?? sourceManifest.id
        guard id == sourceManifest.id else {
            throw DirectToolError.permissionDenied(
                "feature.install id '\(id)' does not match manifest id '\(sourceManifest.id)'."
            )
        }
        guard Self.isValidFeatureID(id) else {
            throw DirectToolError.permissionDenied(
                "Feature id '\(id)' is invalid. Use letters, numbers, dots, underscores, and hyphens."
            )
        }

        let destinationDirectoryURL = featureRootURL()
            .appendingPathComponent(id, isDirectory: true)
            .standardizedFileURL
        let destinationManifestURL = destinationDirectoryURL
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        let copied = try installFeatureDirectory(
            sourceDirectoryURL: sourceDirectoryURL,
            destinationDirectoryURL: destinationDirectoryURL,
            overwrite: arguments.bool("overwrite") ?? false
        )

        try SwiftFeatureRegistry.setFeatureManifestEnabled(
            manifestURL: destinationManifestURL,
            enabled: false,
            fileManager: fileManager
        )

        let shouldBuild = arguments.bool("build") ?? true
        let shouldEnable = arguments.bool("enable") ?? true
        let buildReport: SwiftFeatureBuildReport?
        if shouldBuild {
            var buildArguments: [String: Any] = [
                "manifestPath": destinationManifestURL.path
            ]
            if let timeout = arguments.int("timeoutSeconds", "timeout") {
                buildArguments["timeoutSeconds"] = timeout
            }
            buildReport = try await buildFeature(arguments: buildArguments)
        } else {
            buildReport = nil
        }

        if shouldEnable,
           buildReport?.ok ?? !shouldBuild {
            try await setFeature(id: id, enabled: true)
        } else {
            reloadFeatureBundles()
        }

        let validation = try validateFeature(
            arguments: ["manifestPath": destinationManifestURL.path]
        )
        return SwiftFeatureInstallReport(
            ok: validation.ok && (buildReport?.ok ?? true) && (!shouldEnable || validation.errors.isEmpty),
            id: id,
            sourcePath: sourceDirectoryURL.path,
            destinationPath: destinationDirectoryURL.path,
            manifestPath: destinationManifestURL.path,
            copied: copied,
            built: buildReport?.ok ?? false,
            enabled: shouldEnable && validation.errors.isEmpty && (buildReport?.ok ?? !shouldBuild),
            validation: validation,
            build: buildReport
        )
    }

    private func deleteFeature(
        arguments: [String: Any]
    ) async throws -> SwiftFeatureDeleteReport {
        guard explicitFeatures == nil else {
            throw DirectToolError.permissionDenied(
                "Feature delete is unavailable for an explicitly constructed runtime."
            )
        }

        let id = try Self.requiredFeatureID(arguments)
        let bundledIDs = Set(Self.bundledFeatureDefinitions().map(\.id))
        guard !bundledIDs.contains(id) else {
            throw DirectToolError.permissionDenied(
                "Bundled Swift feature '\(id)' cannot be deleted. Use feature.disable instead."
            )
        }

        guard let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        ),
            let manifestURL = record.manifestURL else {
            throw DirectToolError.permissionDenied("Unknown generated Swift feature: \(id).")
        }

        let rootURLs = featureRootURLs()
        let directoryURL = manifestURL.deletingLastPathComponent().standardizedFileURL
        guard rootURLs.contains(where: { Self.path(directoryURL, isDescendantOf: $0) }),
              !rootURLs.contains(where: { $0.path == directoryURL.path }) else {
            throw DirectToolError.permissionDenied(
                "feature.delete can only remove generated feature packages under the configured features directory."
            )
        }

        try fileManager.removeItem(at: directoryURL)
        return SwiftFeatureDeleteReport(
            ok: true,
            id: id,
            directoryPath: directoryURL.path,
            manifestPath: manifestURL.path,
            removed: true,
            wasEnabled: record.manifestEnabled
        )
    }

    private func reloadFeatureBundles() {
        runtimeDiscoveredToolsByFeatureID.removeAll()
        features = explicitFeatures ?? Self.defaultFeatureBundles(
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        )
    }

    private func renderFeatureMutation(
        action: String,
        id: String
    ) async throws -> String {
        try await renderFeatureList(
            prefix: "Feature '\(id)' \(action).",
            includeTools: true,
            includeDisabled: true,
            discoverRuntimeTools: false
        )
    }

    private func renderFeatureList(
        prefix: String? = nil,
        includeTools: Bool,
        includeDisabled: Bool,
        discoverRuntimeTools: Bool
    ) async throws -> String {
        let statuses = await featureStatuses(
            includeTools: includeTools,
            includeDisabled: includeDisabled,
            discoverRuntimeTools: discoverRuntimeTools
        )
        let payload = SwiftFeatureListPayload(features: statuses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        if let prefix {
            return "\(prefix)\n\(json)"
        }
        return json
    }

    private func renderJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func requiredFeatureID(
        _ arguments: [String: Any]
    ) throws -> String {
        guard let id = arguments
            .string("id", "featureID", "feature_id", "name")?
            .nilIfBlank else {
            throw DirectToolError.missingArgument("id")
        }
        return id
    }

    private func featureManifestURL(
        arguments: [String: Any]
    ) throws -> URL {
        if let manifestPath = arguments
            .string("manifestPath", "manifest_path")?
            .nilIfBlank {
            return Self.manifestURL(from: resolvedFeaturePath(manifestPath))
        }

        if let path = arguments.string("path")?.nilIfBlank {
            return Self.manifestURL(from: resolvedFeaturePath(path))
        }

        let id = try Self.requiredFeatureID(arguments)
        if let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
        ),
           let manifestURL = record.manifestURL {
            return manifestURL
        }

        return featureRootURL()
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
            .standardizedFileURL
    }

    private func scaffoldDirectoryURL(
        id: String,
        arguments: [String: Any]
    ) throws -> URL {
        let rootURL = featureRootURL()
        let directoryURL: URL
        if let directory = arguments
            .string("directory", "directoryPath", "directory_path")?
            .nilIfBlank {
            directoryURL = resolvedFeaturePath(directory)
        } else if let path = arguments.string("path")?.nilIfBlank {
            let url = resolvedFeaturePath(path)
            if url.lastPathComponent == SwiftFeatureRegistry.manifestFilename {
                directoryURL = url.deletingLastPathComponent()
            } else {
                directoryURL = url
            }
        } else {
            directoryURL = rootURL
                .appendingPathComponent(id, isDirectory: true)
                .standardizedFileURL
        }

        guard Self.path(directoryURL, isDescendantOf: rootURL) else {
            throw DirectToolError.permissionDenied(
                "feature.scaffold can only create packages under the generated features directory: \(rootURL.path). Use feature.install for packages prepared elsewhere."
            )
        }
        return directoryURL
    }

    private func installSourceManifestURL(
        arguments: [String: Any]
    ) throws -> URL {
        if let manifestPath = arguments
            .string("manifestPath", "manifest_path")?
            .nilIfBlank {
            return Self.manifestURL(from: resolvedInstallPath(manifestPath))
        }

        if let directory = arguments
            .string("directory", "directoryPath", "directory_path", "path")?
            .nilIfBlank {
            return Self.manifestURL(from: resolvedInstallPath(directory))
        }

        if let id = arguments
            .string("id", "featureID", "feature_id", "name")?
            .nilIfBlank,
           let record = SwiftFeatureRegistry.featureRecord(
            id: id,
            searchRoots: featureSearchRoots,
            fileManager: fileManager
           ),
           let manifestURL = record.manifestURL {
            return manifestURL
        }

        throw DirectToolError.missingArgument("path")
    }

    private func installFeatureDirectory(
        sourceDirectoryURL: URL,
        destinationDirectoryURL: URL,
        overwrite: Bool
    ) throws -> Bool {
        let sourceURL = sourceDirectoryURL.standardizedFileURL
        let destinationURL = destinationDirectoryURL.standardizedFileURL
        guard sourceURL.path != destinationURL.path else {
            return false
        }
        guard !destinationURL.path.hasPrefix(sourceURL.path + "/") else {
            throw DirectToolError.permissionDenied(
                "Refusing to install a feature into a child of its source directory."
            )
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            guard overwrite else {
                throw DirectToolError.permissionDenied(
                    "Feature already exists at \(destinationURL.path). Pass overwrite=true to replace it."
                )
            }
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: true
        )
        try copyFeatureDirectoryContents(
            from: sourceURL,
            to: destinationURL
        )
        return true
    }

    private func copyFeatureDirectoryContents(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws {
        let entries = try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for entryURL in entries {
            guard !Self.excludedInstallEntryNames.contains(entryURL.lastPathComponent) else {
                continue
            }
            let destinationEntryURL = destinationURL.appendingPathComponent(entryURL.lastPathComponent)
            let values = try entryURL.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                try fileManager.createDirectory(
                    at: destinationEntryURL,
                    withIntermediateDirectories: true
                )
                try copyFeatureDirectoryContents(
                    from: entryURL,
                    to: destinationEntryURL
                )
            } else {
                try fileManager.copyItem(
                    at: entryURL,
                    to: destinationEntryURL
                )
            }
        }
    }

    private func featureRootURL() -> URL {
        featureRootURLs().first ?? SwiftFeatureRegistry.appFeatureRootURL(
            fileManager: fileManager
        ).standardizedFileURL
    }

    private func featureRootURLs() -> [URL] {
        (featureSearchRoots ?? [
            SwiftFeatureRegistry.appFeatureRootURL(fileManager: fileManager)
        ]).map(\.standardizedFileURL)
    }

    private func resolvedInstallPath(_ rawPath: String) -> URL {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath)
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }

    private func resolvedFeaturePath(_ rawPath: String) -> URL {
        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath).standardizedFileURL
        }
        return featureRootURL()
            .appendingPathComponent(expandedPath)
            .standardizedFileURL
    }

    private static func manifestURL(from url: URL) -> URL {
        if url.lastPathComponent == SwiftFeatureRegistry.manifestFilename {
            return url.standardizedFileURL
        }
        return url
            .appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
            .standardizedFileURL
    }

    private static func path(_ candidate: URL, isDescendantOf root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath
            || candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
    }

    private static func resolveBuildPackageDirectory(
        build: SwiftFeatureBuildManifest,
        featureDirectoryURL: URL
    ) -> URL {
        guard let packagePath = build.packagePath?.nilIfBlank else {
            return featureDirectoryURL
        }
        return SwiftFeatureRegistry.resolvedExecutableURL(
            packagePath,
            relativeTo: featureDirectoryURL
        )
    }

    private static func validatePackageSwiftToolsVersion(
        packageDirectoryURL: URL
    ) -> [String] {
        let packageURL = packageDirectoryURL.appendingPathComponent("Package.swift")
        guard let firstLine = try? String(contentsOf: packageURL, encoding: .utf8)
            .components(separatedBy: .newlines)
            .first else {
            return ["Package.swift not found at \(packageURL.path)."]
        }

        let expected = "// swift-tools-version: \(generatedSwiftToolsVersion)"
        guard firstLine.trimmingCharacters(in: .whitespacesAndNewlines) == expected else {
            return [
                "Package.swift must target Swift tools \(generatedSwiftToolsVersion). Expected first line: \(expected)"
            ]
        }
        return []
    }

    private static func validationErrorsForToolNames(
        _ toolNames: [String]
    ) -> [String] {
        var errors: [String] = []
        let duplicates = Dictionary(grouping: toolNames, by: { $0 })
            .filter { !$0.key.isEmpty && $0.value.count > 1 }
            .map(\.key)
            .sorted()
        if !duplicates.isEmpty {
            errors.append("Duplicate tool names: \(duplicates.joined(separator: ", ")).")
        }

        let reservedToolNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        for toolName in toolNames {
            if toolName.nilIfBlank == nil {
                errors.append("Feature contains an empty tool name.")
            } else if toolName == "local.exec" {
                errors.append("local.exec is core and cannot be implemented by a feature.")
            } else if toolName.hasPrefix("feature.") {
                errors.append("Tool namespace 'feature.' is reserved for kernel feature management: \(toolName).")
            } else if reservedToolNames.contains(toolName) {
                errors.append("Tool name '\(toolName)' already exists in the core catalog.")
            }
        }
        return errors
    }

    private static func isValidFeatureID(_ id: String) -> Bool {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return false
        }
        return !id.contains("..")
            && !id.contains("/")
            && !id.contains("\\")
    }

    private static let excludedInstallEntryNames: Set<String> = [
        ".build",
        ".git",
        ".swiftpm",
        ".DS_Store"
    ]

    private static func swiftExecutableURL(fileManager: FileManager) -> URL {
        let environment = ProcessInfo.processInfo.environment
        let candidates = [
            environment["SWIFT_EXECUTABLE"],
            "/usr/bin/swift",
            "/Library/Developer/CommandLineTools/usr/bin/swift",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift",
            "/opt/homebrew/bin/swift",
            "/usr/local/bin/swift"
        ].compactMap { $0?.nilIfBlank }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return URL(fileURLWithPath: "/usr/bin/swift")
    }

    private enum ScaffoldTemplate {
        case basic
        case mcpBridge
    }

    private static func scaffoldTemplate(arguments: [String: Any]) -> ScaffoldTemplate {
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

    private static func defaultScaffoldDescription(
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

    private static func normalizedToolPrefix(_ rawPrefix: String) -> String {
        let prefix = rawPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else {
            return prefix
        }
        return prefix.hasSuffix(".") ? prefix : "\(prefix)."
    }

    private static func validateMCPBridgeToolPrefix(_ prefix: String) throws {
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

    private static func defaultMLXServerPackagePath(fileManager: FileManager) -> String {
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

    private static func stringArrayArgument(
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

    private static func stringDictionaryArgument(
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

    private static func targetName(for id: String) -> String {
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

    private static func defaultToolPrefix(for id: String) -> String {
        let normalized = id
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "_"
            }
        let value = String(normalized)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return value.nilIfBlank ?? "generated"
    }

    private static func packageManifestContents(
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

    private static func mcpBridgePackageManifestContents(
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

    private static func featureMainContents(
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

        private struct InvocationContext {
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

            private static func invoke(
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

            private static func writeJSON<T: Encodable>(_ value: T) throws {
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

            private static func optionValue(_ option: String, in arguments: [String]) -> String? {
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

    private static func mcpBridgeMainContents(
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

            private static func listTools() async throws -> [MLXFeatureToolDescriptor] {
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

            private static func invoke(
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

            private static func configuration() throws -> MCPServerConfiguration {
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

            private static func decodeArguments(from data: Data) throws -> [String: JSONValue] {
                guard !data.isEmpty else {
                    return [:]
                }

                let value = try JSONDecoder().decode(JSONValue.self, from: data)
                guard case let .object(arguments) = value else {
                    throw MCPBridgeFeatureError.invalidArguments
                }
                return arguments
            }

            private static func emitJSON<T: Encodable>(_ value: T) throws {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let data = try encoder.encode(value)
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }

            private static func terminate(code: Int32) -> Never {
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

    private static func featureManifestContents(
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
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func mcpBridgeFeatureManifestContents(
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
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func toolNamePrefix(from toolName: String) -> String {
        guard let dotIndex = toolName.lastIndex(of: ".") else {
            return "\(toolName)."
        }
        return String(toolName[...dotIndex])
    }

    private static func swiftStringArrayLiteral(_ values: [String]) -> String {
        let renderedValues = values
            .map(swiftStringLiteral)
            .joined(separator: ", ")
        return "[\(renderedValues)]"
    }

    private static func swiftStringDictionaryLiteral(_ values: [String: String]) -> String {
        guard !values.isEmpty else {
            return "[:]"
        }
        let renderedValues = values
            .sorted { $0.key < $1.key }
            .map { "\(swiftStringLiteral($0.key)): \(swiftStringLiteral($0.value))" }
            .joined(separator: ", ")
        return "[\(renderedValues)]"
    }

    private static func swiftStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    public static func defaultFeatureBundles(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureBundle] {
        bundledFeatureBundles(fileManager: fileManager)
            + SwiftFeatureRegistry.discoverFeatureBundles(
                searchRoots: searchRoots,
                fileManager: fileManager
            )
    }

    public static func defaultFeatureToolDescriptors(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        includeDisabled: Bool = false
    ) -> [DirectToolDescriptor] {
        let bundledTools = bundledFeatureToolDescriptors(
            fileManager: fileManager,
            includeDisabled: includeDisabled
        )
        let records = defaultFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        let tools = records
            .filter { $0.source != .bundled }
            .filter { includeDisabled || $0.enabled }
            .flatMap(\.tools)
        return DirectToolExecutor.canonicalized(
            bundledTools + ToolDescriptor.canonicalized(tools).map {
                DirectToolDescriptor(
                    name: $0.name,
                    description: $0.description,
                    inputSchema: $0.inputSchema
                )
            }
        )
    }

    public static func defaultFeatureStatuses(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        includeTools: Bool = true,
        includeDisabled: Bool = true
    ) -> [SwiftFeatureStatus] {
        defaultFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        .filter { includeDisabled || $0.enabled }
        .map { record in
            status(
                from: record,
                tools: includeTools ? record.tools.map(\.name) : []
            )
        }
    }

    private static func bundledFeatureToolDescriptors(
        fileManager: FileManager,
        includeDisabled: Bool
    ) -> [DirectToolDescriptor] {
        let state = SwiftFeatureStateStore.load(fileManager: fileManager)
        let tools = bundledFeatureDefinitions()
            .filter { includeDisabled || state.bundledFeatureIsEnabled(id: $0.id) }
            .flatMap(\.tools)
        return ToolDescriptor.canonicalized(tools).map {
            DirectToolDescriptor(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }

    private static func bundledFeatureBundles(
        fileManager: FileManager
    ) -> [SwiftFeatureBundle] {
        let state = SwiftFeatureStateStore.load(fileManager: fileManager)
        return bundledFeatureDefinitions()
            .filter { state.bundledFeatureIsEnabled(id: $0.id) }
            .compactMap { definition in
                guard let executableURL = availableBundledExecutableURL(
                    named: definition.executableName,
                    fileManager: fileManager
                ) else {
                    return nil
                }
                return definition.bundle(executableURL: executableURL)
            }
    }

    private static func bundledFeatureDefinitions() -> [BundledFeatureDefinition] {
        [
            BundledFeatureDefinition(
                id: "mlx-search-tools",
                executableName: "mlx-search-tools-feature",
                tools: bundledSearchToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "mlx-web-tools",
                executableName: "mlx-web-tools-feature",
                tools: bundledWebToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "mlx-git-tools",
                executableName: "mlx-git-tools-feature",
                tools: bundledGitToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "mlx-jira-tools",
                executableName: "mlx-jira-tools-feature",
                tools: bundledJiraToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "mlx-xcode-tools",
                executableName: "mlx-xcode-tools-feature",
                tools: [],
                toolNamePrefixes: ["xcode.", "Xcode"],
                toolNameAliases: [
                    "BuildProject",
                    "DocumentationSearch",
                    "ExecuteSnippet",
                    "GetBuildLog",
                    "GetTestList",
                    "RenderPreview",
                    "RunAllTests",
                    "RunSomeTests"
                ],
                discoversToolsAtRuntime: true
            ),
            BundledFeatureDefinition(
                id: "mlx-figma-tools",
                executableName: "mlx-figma-tools-feature",
                tools: [],
                toolNamePrefixes: ["figma."],
                discoversToolsAtRuntime: true
            )
        ]
    }

    private static func defaultFeatureRecords(
        searchRoots: [URL]?,
        fileManager: FileManager
    ) -> [SwiftFeatureRecord] {
        let state = SwiftFeatureStateStore.load(fileManager: fileManager)
        let bundledRecords = bundledFeatureDefinitions().map { feature in
            let executableURL = bundledExecutableStatusURL(
                named: feature.executableName,
                fileManager: fileManager
            )
            return SwiftFeatureRecord(
                id: feature.id,
                displayName: nil,
                description: nil,
                source: .bundled,
                executableURL: executableURL,
                manifestURL: nil,
                manifestEnabled: state.bundledFeatureIsEnabled(id: feature.id),
                executableAvailable: fileManager.isExecutableFile(atPath: executableURL.path),
                tools: feature.tools,
                toolNamePrefixes: feature.toolNamePrefixes,
                toolNameAliases: feature.toolNameAliases,
                discoversToolsAtRuntime: feature.discoversToolsAtRuntime,
                build: nil,
                generated: nil,
                issue: nil
            )
        }
        return bundledRecords + SwiftFeatureRegistry.discoverFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
    }

    private static func status(
        from record: SwiftFeatureRecord,
        tools: [String]
    ) -> SwiftFeatureStatus {
        status(
            id: record.id,
            displayName: record.displayName,
            description: record.description,
            source: record.source,
            executableURL: record.executableURL,
            enabled: record.enabled,
            available: record.executableAvailable,
            manifestPath: record.manifestURL?.path,
            issue: record.issue,
            tools: tools,
            toolNamePrefixes: record.toolNamePrefixes,
            toolNameAliases: record.toolNameAliases,
            discoversToolsAtRuntime: record.discoversToolsAtRuntime,
            build: record.build,
            generated: record.generated
        )
    }

    private static func status(
        from feature: SwiftFeatureBundle,
        enabled: Bool,
        available: Bool,
        manifestPath: String?,
        issue: String?,
        tools: [String]
    ) -> SwiftFeatureStatus {
        status(
            id: feature.id,
            displayName: nil,
            description: nil,
            source: feature.source,
            executableURL: feature.executableURL,
            enabled: enabled,
            available: available,
            manifestPath: manifestPath,
            issue: issue,
            tools: tools,
            toolNamePrefixes: feature.toolNamePrefixes,
            toolNameAliases: feature.toolNameAliases,
            discoversToolsAtRuntime: feature.discoversToolsAtRuntime,
            build: nil,
            generated: nil
        )
    }

    private static func status(
        id: String,
        displayName: String?,
        description: String?,
        source: SwiftFeatureBundleSource,
        executableURL: URL,
        enabled: Bool,
        available: Bool,
        manifestPath: String?,
        issue: String?,
        tools: [String],
        toolNamePrefixes: [String],
        toolNameAliases: [String],
        discoversToolsAtRuntime: Bool,
        build: SwiftFeatureBuildManifest?,
        generated: SwiftFeatureGeneratedManifest?
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: id,
            displayName: displayName,
            description: description,
            source: source,
            enabled: enabled,
            available: available,
            executablePath: executableURL.path,
            manifestPath: manifestPath,
            tools: tools.sorted(),
            toolNamePrefixes: toolNamePrefixes,
            toolNameAliases: toolNameAliases,
            discoversToolsAtRuntime: discoversToolsAtRuntime,
            build: build,
            generated: generated,
            issue: issue
        )
    }

    private static func bundledSearchToolDescriptors() -> [ToolDescriptor] {
        DirectToolCatalog.localSearchDescriptors.map(\.toolDescriptor) + [
            ToolDescriptor(
                name: "search.grep",
                description: "Searches text with grep from a local path.",
                inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}},"required":["pattern"]}"#
            )
        ]
    }

    private static func bundledWebToolDescriptors() -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "web.search",
                description: "Searches the public web and returns matching results with titles, URLs, and snippets.",
                inputSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"number"},"domains":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#
            ),
            ToolDescriptor(
                name: "web.fetch",
                description: "Fetches an HTTP or HTTPS URL and returns response metadata plus a UTF-8 text preview.",
                inputSchema: #"{"type":"object","properties":{"url":{"type":"string"},"maxBytes":{"type":"number"},"timeoutSeconds":{"type":"number"}},"required":["url"]}"#
            )
        ]
    }

    private static func bundledGitToolDescriptors() -> [ToolDescriptor] {
        #if canImport(Darwin) || canImport(Glibc)
        DirectToolCatalog.macOSProcessDescriptors
            .filter { $0.name.hasPrefix("git.") }
            .map(\.toolDescriptor)
        #else
        []
        #endif
    }

    private static func bundledJiraToolDescriptors() -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "jira.search",
                description: "Searches Jira issues by issue key, issue URL, or text and returns selectable issue summaries.",
                inputSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
            ),
            ToolDescriptor(
                name: "jira.read",
                description: "Loads a Jira issue and returns task context for the model without creating a local task.",
                inputSchema: #"{"type":"object","properties":{"issueKey":{"type":"string"},"issue_key":{"type":"string"},"key":{"type":"string"},"url":{"type":"string"},"query":{"type":"string"},"includeRaw":{"type":"boolean"},"include_raw":{"type":"boolean"}}}"#
            ),
            ToolDescriptor(
                name: "jira.signOut",
                description: "Clears the persisted Jira API token used by the Jira tools.",
                inputSchema: #"{"type":"object","properties":{}}"#
            )
        ]
    }

    private static func availableBundledExecutableURL(
        named executableName: String,
        fileManager: FileManager
    ) -> URL? {
        for executableURL in bundledExecutableCandidateURLs(
            named: executableName,
            fileManager: fileManager
        ) {
            if fileManager.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        }
        return nil
    }

    private static func bundledExecutableStatusURL(
        named executableName: String,
        fileManager: FileManager
    ) -> URL {
        availableBundledExecutableURL(
            named: executableName,
            fileManager: fileManager
        ) ?? bundledExecutableCandidateURLs(
            named: executableName,
            fileManager: fileManager
        ).first
            ?? URL(fileURLWithPath: executableName).standardizedFileURL
    }

    private static func bundledExecutableCandidateURLs(
        named executableName: String,
        fileManager: FileManager
    ) -> [URL] {
        var seenPaths = Set<String>()
        let baseDirectories = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0)
                    .standardizedFileURL
                    .deletingLastPathComponent()
            }
        ].compactMap { $0 }
        let workingDirectoryURL = URL(
            fileURLWithPath: fileManager.currentDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let buildDirectoryURL = workingDirectoryURL
            .appendingPathComponent(".build", isDirectory: true)
        let buildProductDirectories = swiftPMBuildProductDirectories(
            buildDirectoryURL: buildDirectoryURL,
            fileManager: fileManager
        )
        let candidateDirectories = baseDirectories.flatMap { directoryURL in
            var directories = [directoryURL]
            var parentURL = directoryURL
            for _ in 0..<4 {
                parentURL = parentURL.deletingLastPathComponent()
                directories.append(parentURL)
            }
            return directories
        } + buildProductDirectories

        return candidateDirectories.compactMap { directoryURL in
            let executableURL = directoryURL
                .appendingPathComponent(executableName)
                .standardizedFileURL
            guard seenPaths.insert(executableURL.path).inserted else {
                return nil
            }
            return executableURL
        }
    }

    private static func swiftPMBuildProductDirectories(
        buildDirectoryURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        var directories = [
            buildDirectoryURL.appendingPathComponent("debug", isDirectory: true),
            buildDirectoryURL.appendingPathComponent("release", isDirectory: true)
        ]
        guard let children = try? fileManager.contentsOfDirectory(
            at: buildDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directories
        }

        for childURL in children {
            guard (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            directories.append(childURL.appendingPathComponent("debug", isDirectory: true))
            directories.append(childURL.appendingPathComponent("release", isDirectory: true))
        }
        return directories
    }

    private static func renderInvocationResult(
        _ result: AsyncProcessResult,
        feature: SwiftFeatureBundle
    ) throws -> String {
        guard !result.timedOut else {
            throw DirectToolError.permissionDenied(
                "Swift feature '\(feature.id)' timed out."
            )
        }

        guard result.exitCode == 0 else {
            throw DirectToolError.permissionDenied(
                processFailureMessage(result, feature: feature)
            )
        }

        let response = try JSONDecoder().decode(
            SwiftFeatureInvocationResponse.self,
            from: result.stdoutData
        )
        guard response.ok else {
            throw DirectToolError.permissionDenied(
                response.error?.nilIfBlank
                    ?? "Swift feature '\(feature.id)' returned an error."
            )
        }
        return renderOutput(response.output)
    }

    private static func processFailureMessage(
        _ result: AsyncProcessResult,
        feature: SwiftFeatureBundle
    ) -> String {
        var lines = [
            "Swift feature '\(feature.id)' failed with exit code \(result.exitCode)."
        ]
        if let stdout = result.stdout.nilIfBlank {
            lines.append("stdout:\n\(stdout)")
        }
        if let stderr = result.stderr.nilIfBlank {
            lines.append("stderr:\n\(stderr)")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderOutput(_ output: JSONValue?) -> String {
        guard let output else {
            return "<no output>"
        }
        switch output {
        case let .string(value):
            return value
        case let .number(value):
            return "\(value)"
        case let .bool(value):
            return "\(value)"
        case .null:
            return "null"
        case .array, .object:
            return output.prettyPrinted()
        }
    }

    private func tools(for feature: SwiftFeatureBundle) async -> [ToolDescriptor] {
        guard feature.discoversToolsAtRuntime else {
            return feature.tools
        }

        if let cachedTools = runtimeDiscoveredToolsByFeatureID[feature.id] {
            return cachedTools
        }

        let discoveredTools = (try? await Self.discoverRuntimeTools(feature: feature)) ?? []
        let canonicalTools = ToolDescriptor.canonicalized(feature.tools + discoveredTools)
        runtimeDiscoveredToolsByFeatureID[feature.id] = canonicalTools
        return canonicalTools
    }

    private static func discoverRuntimeTools(
        feature: SwiftFeatureBundle
    ) async throws -> [ToolDescriptor] {
        let result = try await AsyncProcessRunner.run(
            executableURL: feature.executableURL,
            arguments: ["--list-tools"],
            workingDirectory: feature.executableURL.deletingLastPathComponent(),
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 10
        )

        guard !result.timedOut,
              result.exitCode == 0 else {
            return []
        }

        let response = try JSONDecoder().decode(
            SwiftFeatureListToolsResponse.self,
            from: result.stdoutData
        )
        return response.tools
    }
}

private struct SwiftFeatureListToolsResponse: Decodable {
    let tools: [ToolDescriptor]
}

private struct SwiftFeatureInvocationResponse: Decodable {
    let ok: Bool
    let output: JSONValue?
    let error: String?
}

private struct SwiftFeatureListPayload: Codable {
    let features: [SwiftFeatureStatus]
}
