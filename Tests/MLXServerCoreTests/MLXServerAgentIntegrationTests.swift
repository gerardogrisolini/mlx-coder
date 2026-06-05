//
//  MLXServerAgentIntegrationTests.swift
//  mlx-server
//

import Foundation
import Testing
@testable import MLXServerCore

@Test
func codexCLIProfileWritesExpectedTOMLAndCatalog() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    let configURL = MLXServerAgentIntegrationService.codexConfigURL(
        target: .desktop,
        homeDirectory: home
    )
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try """
    [model_providers.openai]
    name = "OpenAI"

    [profiles.default]
    model = "gpt-5"
    model_provider = "openai"
    """.write(to: configURL, atomically: true, encoding: .utf8)

    try MLXServerAgentIntegrationService.configureCodexCLIProfile(
        configuration: MLXServerAgentIntegrationConfiguration(
            baseURL: " http://127.0.0.1:8080/ ",
            modelID: " mlx-community/test-model ",
            contextWindow: 262_144,
            apiKey: #"local "secret""#
        ),
        homeDirectory: home
    )

    let configText = try String(contentsOf: configURL, encoding: .utf8)
    let catalogURL = codexCatalogURL(home: home, target: .desktop)
    #expect(configText.contains("[model_providers.openai]"))
    #expect(configText.contains("[profiles.default]"))
    #expect(configText.contains("[model_providers.\"mlx-server\"]"))
    #expect(configText.contains("name = \"mlx-server\""))
    #expect(configText.contains("base_url = \"http://127.0.0.1:8080/v1\""))
    #expect(configText.contains("wire_api = \"responses\""))
    #expect(configText.contains(#"http_headers = { Authorization = "Bearer local \"secret\"" }"#))
    #expect(configText.contains("[profiles.\"mlx-server\"]"))
    #expect(configText.contains("model = \"mlx-community/test-model\""))
    #expect(configText.contains("openai_base_url = \"http://127.0.0.1:8080/v1\""))
    #expect(configText.contains("model_provider = \"mlx-server\""))
    #expect(configText.contains("forced_login_method = \"api\""))
    #expect(configText.contains("model_catalog_json = \"\(catalogURL.path)\""))

    let catalog = try loadCodexCatalog(at: catalogURL)
    let model = try #require(catalog.models.first)
    #expect(model.slug == "mlx-community/test-model")
    #expect(model.displayName == "mlx-community/test-model")
    #expect(model.contextWindow == 262_144)
    #expect(model.maxContextWindow == 262_144)
    #expect(model.supportedInAPI)
    #expect(model.truncationPolicy.mode == "bytes")
    #expect(model.truncationPolicy.limit == 10_000)
}

@Test
func codexAppProfileWritesExpectedTOMLWithoutForcedLogin() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    try MLXServerAgentIntegrationService.configureCodexAppProfile(
        target: .desktop,
        configuration: MLXServerAgentIntegrationConfiguration(
            baseURL: "http://127.0.0.1:8080/v1",
            modelID: "mlx-community/app-model",
            contextWindow: nil
        ),
        homeDirectory: home
    )

    let configURL = MLXServerAgentIntegrationService.codexConfigURL(
        target: .desktop,
        homeDirectory: home
    )
    let configText = try String(contentsOf: configURL, encoding: .utf8)
    #expect(configText.contains("[profiles.\"mlx-server-codex-app\"]"))
    #expect(configText.contains("model = \"mlx-community/app-model\""))
    #expect(configText.contains("model_provider = \"mlx-server\""))
    #expect(!configText.contains("forced_login_method"))

    let catalog = try loadCodexCatalog(at: codexCatalogURL(home: home, target: .desktop))
    let model = try #require(catalog.models.first)
    #expect(model.slug == "mlx-community/app-model")
    #expect(model.contextWindow == 128_000)
}

@Test
func xcodeCodexProfileWritesOnlyXcodeConfigurationTree() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    try MLXServerAgentIntegrationService.configureCodexAppProfile(
        target: .xcode,
        configuration: MLXServerAgentIntegrationConfiguration(
            baseURL: "http://127.0.0.1:9090",
            modelID: "mlx-community/xcode-model",
            contextWindow: 65_536,
            apiKey: "xcode-secret"
        ),
        homeDirectory: home
    )

    let desktopConfigURL = MLXServerAgentIntegrationService.codexConfigURL(
        target: .desktop,
        homeDirectory: home
    )
    let xcodeConfigURL = MLXServerAgentIntegrationService.codexConfigURL(
        target: .xcode,
        homeDirectory: home
    )
    #expect(!FileManager.default.fileExists(atPath: desktopConfigURL.path))
    #expect(FileManager.default.fileExists(atPath: xcodeConfigURL.path))
    #expect(xcodeConfigURL.path.contains("Library/Developer/Xcode/CodingAssistant/codex/config.toml"))

    let configText = try String(contentsOf: xcodeConfigURL, encoding: .utf8)
    #expect(configText.contains("[model_providers.\"mlx-server\"]"))
    #expect(!configText.contains("[profiles.\"mlx-server-codex-app\"]"))
    #expect(configText.contains("model_provider = \"mlx-server\""))
    #expect(configText.contains("forced_login_method = \"api\""))
    #expect(configText.contains("base_url = \"http://127.0.0.1:9090/v1\""))
    #expect(configText.contains("http_headers = { Authorization = \"Bearer xcode-secret\" }"))
    #expect(configText.contains("model = \"mlx-community/xcode-model\""))
    #expect(!FileManager.default.fileExists(atPath: codexCatalogURL(home: home, target: .xcode).path))
}

@Test
func reconfiguringCodexProfileReplacesOwnedBlocks() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    try MLXServerAgentIntegrationService.configureCodexCLIProfile(
        configuration: MLXServerAgentIntegrationConfiguration(
            baseURL: "http://127.0.0.1:8080",
            modelID: "mlx-community/old-model"
        ),
        homeDirectory: home
    )
    try MLXServerAgentIntegrationService.configureCodexCLIProfile(
        configuration: MLXServerAgentIntegrationConfiguration(
            baseURL: "http://127.0.0.1:9090",
            modelID: "mlx-community/new-model"
        ),
        homeDirectory: home
    )

    let configText = try String(
        contentsOf: MLXServerAgentIntegrationService.codexConfigURL(
            target: .desktop,
            homeDirectory: home
        ),
        encoding: .utf8
    )
    #expect(countOccurrences(of: "[model_providers.\"mlx-server\"]", in: configText) == 1)
    #expect(countOccurrences(of: "[profiles.\"mlx-server\"]", in: configText) == 1)
    #expect(configText.contains("base_url = \"http://127.0.0.1:9090/v1\""))
    #expect(configText.contains("model = \"mlx-community/new-model\""))
    #expect(!configText.contains("old-model"))
    #expect(!configText.contains("http://127.0.0.1:8080"))
}

@Test
func codexDesktopProfilesShareProviderWithoutClobberingEachOther() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    let configuration = MLXServerAgentIntegrationConfiguration(
        baseURL: "http://127.0.0.1:8080",
        modelID: "mlx-community/test-model",
        contextWindow: 262_144
    )

    try MLXServerAgentIntegrationService.configureCodexCLIProfile(
        configuration: configuration,
        homeDirectory: home
    )
    try MLXServerAgentIntegrationService.configureCodexAppProfile(
        target: .desktop,
        configuration: configuration,
        homeDirectory: home
    )

    var status = MLXServerAgentIntegrationService.status(homeDirectory: home)
    #expect(status.codexCLIEnabled)
    #expect(status.codexAppEnabled)

    try MLXServerAgentIntegrationService.removeCodexCLIProfile(homeDirectory: home)

    status = MLXServerAgentIntegrationService.status(homeDirectory: home)
    #expect(!status.codexCLIEnabled)
    #expect(status.codexAppEnabled)

    let configText = try String(
        contentsOf: MLXServerAgentIntegrationService.codexConfigURL(
            target: .desktop,
            homeDirectory: home
        ),
        encoding: .utf8
    )
    #expect(configText.contains("[profiles.\"mlx-server-codex-app\"]"))
    #expect(configText.contains("[model_providers.\"mlx-server\"]"))
    #expect(!configText.contains("[profiles.\"mlx-server\"]"))
}

@Test
func removingLastCodexProfileRemovesOwnedProviderAndCatalog() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    let configuration = MLXServerAgentIntegrationConfiguration(
        baseURL: "http://127.0.0.1:8080/v1",
        modelID: "mlx-community/test-model"
    )
    try MLXServerAgentIntegrationService.configureCodexCLIProfile(
        configuration: configuration,
        homeDirectory: home
    )

    let catalogURL = home
        .appendingPathComponent(".codex", isDirectory: true)
        .appendingPathComponent(MLXServerAgentIntegrationService.codexModelCatalogFilename)
    #expect(FileManager.default.fileExists(atPath: catalogURL.path))

    try MLXServerAgentIntegrationService.removeCodexCLIProfile(homeDirectory: home)

    let configText = try String(
        contentsOf: MLXServerAgentIntegrationService.codexConfigURL(
            target: .desktop,
            homeDirectory: home
        ),
        encoding: .utf8
    )
    #expect(!configText.contains("[profiles.\"mlx-server\"]"))
    #expect(!configText.contains("[model_providers.\"mlx-server\"]"))
    #expect(!FileManager.default.fileExists(atPath: catalogURL.path))
}

@Test
func xcodeAgentIntegrationsUseDedicatedConfigurationFiles() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }

    let configuration = MLXServerAgentIntegrationConfiguration(
        baseURL: "http://127.0.0.1:8080/v1",
        modelID: "mlx-community/test-model",
        apiKey: "claude-secret"
    )
    try MLXServerAgentIntegrationService.configureCodexAppProfile(
        target: .xcode,
        configuration: configuration,
        homeDirectory: home
    )
    try MLXServerAgentIntegrationService.configureXcodeClaudeCode(
        configuration: configuration,
        homeDirectory: home
    )

    let claudeSettings = try loadClaudeSettings(
        at: MLXServerAgentIntegrationService.xcodeClaudeCodeSettingsURL(homeDirectory: home)
    )
    #expect(claudeSettings.env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:8080")
    #expect(claudeSettings.env["ANTHROPIC_AUTH_TOKEN"] == "claude-secret")
    #expect(claudeSettings.env["API_TIMEOUT_MS"] == "3000000")
    #expect(claudeSettings.env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] == "1")
    #expect(claudeSettings.env["ANTHROPIC_MODEL"] == "mlx-community/test-model")
    #expect(claudeSettings.env["DISABLE_AUTOUPDATER"] == "1")

    var status = MLXServerAgentIntegrationService.status(homeDirectory: home)
    #expect(status.codexXcodeAppEnabled)
    #expect(status.xcodeClaudeCodeEnabled)

    try MLXServerAgentIntegrationService.removeCodexAppProfile(
        target: .xcode,
        homeDirectory: home
    )
    try MLXServerAgentIntegrationService.removeXcodeClaudeCode(homeDirectory: home)

    status = MLXServerAgentIntegrationService.status(homeDirectory: home)
    #expect(!status.codexXcodeAppEnabled)
    #expect(!status.xcodeClaudeCodeEnabled)
}

@Test
func aionUIExecutableCommandUsesSwiftRunForSourceBuild() throws {
    let rootURL = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try "// swift-tools-version: 6.3\n".write(
        to: rootURL.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
    let executableURL = rootURL
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("arm64-apple-macosx", isDirectory: true)
        .appendingPathComponent("debug", isDirectory: true)
        .appendingPathComponent("mlx-server")
    try writeExecutable(at: executableURL)

    let command = try #require(
        MLXServerAgentIntegrationService.aionUIExecutableCommand(
            named: "mlx-server",
            preferredURL: executableURL,
            relativeTo: nil,
            fileManager: .default
        )
    )

    #expect(command.command == MLXServerAgentIntegrationService.swiftExecutableCommand(fileManager: .default))
    #expect(command.argsPrefix == ["run", "--package-path", rootURL.path, "mlx-server"])
    #expect(command.resolvedURL == executableURL.standardizedFileURL)

    let coderCommand = try #require(
        MLXServerAgentIntegrationService.aionUIExecutableCommand(
            named: "mlx-coder",
            preferredURL: nil,
            relativeTo: executableURL.deletingLastPathComponent(),
            sourcePackageRootURL: rootURL,
            fileManager: .default
        )
    )
    #expect(coderCommand.command == command.command)
    #expect(coderCommand.argsPrefix == ["run", "--package-path", rootURL.path, "mlx-coder"])
}

@Test
func aionUIExecutableCommandUsesManualInstallPathOutsideSourceBuild() throws {
    let rootURL = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: rootURL)
    }
    let executableURL = rootURL
        .appendingPathComponent("bin", isDirectory: true)
        .appendingPathComponent("mlx-coder")
    try writeExecutable(at: executableURL)

    let command = try #require(
        MLXServerAgentIntegrationService.aionUIExecutableCommand(
            named: "mlx-coder",
            preferredURL: executableURL,
            relativeTo: nil,
            fileManager: .default
        )
    )

    #expect(command.command == executableURL.standardizedFileURL.path)
    #expect(command.argsPrefix.isEmpty)
}

private func temporaryHomeDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-server-agent-tests-\(UUID().uuidString)", isDirectory: true)
}

private func writeExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: url.path
    )
}

private func codexCatalogURL(
    home: URL,
    target: MLXServerCodexConfigurationTarget
) -> URL {
    MLXServerAgentIntegrationService.codexConfigURL(
        target: target,
        homeDirectory: home
    )
    .deletingLastPathComponent()
    .appendingPathComponent(MLXServerAgentIntegrationService.codexModelCatalogFilename)
}

private func loadCodexCatalog(at url: URL) throws -> TestCodexCatalog {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TestCodexCatalog.self, from: data)
}

private func loadClaudeSettings(at url: URL) throws -> TestClaudeSettings {
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(TestClaudeSettings.self, from: data)
}

private func countOccurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private struct TestCodexCatalog: Decodable {
    var models: [TestCodexCatalogModel]
}

private struct TestCodexCatalogModel: Decodable {
    var slug: String
    var displayName: String
    var contextWindow: Int
    var maxContextWindow: Int
    var supportedInAPI: Bool
    var truncationPolicy: TestCodexTruncationPolicy

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case contextWindow = "context_window"
        case maxContextWindow = "max_context_window"
        case supportedInAPI = "supported_in_api"
        case truncationPolicy = "truncation_policy"
    }
}

private struct TestCodexTruncationPolicy: Decodable {
    var mode: String
    var limit: Int
}

private struct TestClaudeSettings: Decodable {
    var env: [String: String]
}

@Test
func aionUIModelConfigOptionsIncludeThinkingMetadata() throws {
    let json = try MLXServerAgentIntegrationService.aionUIModelConfigOptionsJSON(
        models: ["chatgpt:gpt-5", "mlx-community/model"],
        thinkingOptions: ["off", "medium", "xhigh"],
        defaultThinking: "medium"
    )

    let data = try #require(json.data(using: .utf8))
    let decoded = try JSONDecoder().decode(TestAionUIAgentConfigOptions.self, from: data)
    let thinking = try #require(decoded.configOptions.first { $0.id == "thinking" })

    #expect(thinking.name == "Thinking")
    #expect(thinking.category == "model")
    #expect(thinking.type == "select")
    #expect(thinking.currentValue == "medium")
    #expect(thinking.options.map(\.value) == ["off", "medium", "xhigh"])
    #expect(thinking.options.map(\.name) == ["Off", "Medium", "XHigh"])
}

@Test
func aionUICoderThinkingMetadataReadsSettingsManifest() throws {
    let home = temporaryHomeDirectory()
    defer {
        try? FileManager.default.removeItem(at: home)
    }
    let settingsURL = home
        .appendingPathComponent(".mlx-coder", isDirectory: true)
        .appendingPathComponent("settings.json")
    try FileManager.default.createDirectory(
        at: settingsURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try """
    {
      "version": 1,
      "models": [
        {
          "id": "first-model",
          "kind": "remoteAPI",
          "modelID": "provider/first",
          "thinking": {
            "options": ["off", "medium"],
            "default": "medium"
          }
        },
        {
          "id": "second-model",
          "kind": "remoteAPI",
          "modelID": "provider/second",
          "thinking": {
            "options": ["medium", "high"]
          }
        }
      ]
    }
    """.write(to: settingsURL, atomically: true, encoding: .utf8)

    let metadata = MLXServerAgentIntegrationService.aionUICoderThinkingOptions(
        homeDirectory: home
    )

    #expect(metadata.options == ["off", "medium", "high"])
    #expect(metadata.defaultSelection == "medium")
}

private struct TestAionUIAgentConfigOptions: Decodable {
    var configOptions: [TestAionUIAgentConfigOption]

    enum CodingKeys: String, CodingKey {
        case configOptions = "config_options"
    }
}

private struct TestAionUIAgentConfigOption: Decodable {
    var id: String
    var name: String
    var category: String
    var type: String
    var currentValue: String
    var options: [TestAionUIAgentConfigOptionValue]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case category
        case type
        case currentValue = "current_value"
        case options
    }
}


private struct TestAionUIAgentConfigOptionValue: Decodable {
    var value: String
    var name: String
    var description: String
}
