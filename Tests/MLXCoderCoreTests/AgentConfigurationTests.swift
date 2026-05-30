import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentConfigurationTests {
    @Test
    func toolSelectionKeysKeepCoreAndFeaturePackagesDistinct() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-search-tools",
                    source: .bundled,
                    tools: ["search.glob", "search.grep"]
                ),
                featureStatus(
                    id: "mlx-git-tools",
                    source: .bundled,
                    tools: ["git.status"]
                )
            ]
        )

        let selectedKeys = try TerminalChat.parseToolSelection(
            "shell files text feature-builder search git",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(allowedToolNames.contains("feature.list"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("git.status"))
    }

    @Test
    func defaultAgentProfilesEnableCoreAndFeaturePackageTools() {
        let profile = AgentProfile(
            id: "default",
            name: "Default",
            tools: AgentProfileStore.defaultToolNames
        )
        let allowedToolNames = profile.allowedToolNames()

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("local.readFile"))
        #expect(allowedToolNames.contains("search.grep"))
        #expect(allowedToolNames.contains("text.wc"))
        #expect(allowedToolNames.contains("feature.list"))
    }

    @Test
    func toolSelectionCatalogListsBundledAndGeneratedFeaturePackagesTogether() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-git-tools",
                    source: .bundled,
                    tools: ["git.status", "git.log"]
                ),
                featureStatus(
                    id: "live-git-branch",
                    displayName: "Live Git Branch",
                    source: .generated,
                    tools: ["live.git_current_branch"]
                )
            ]
        )

        #expect(items.map(\.title).contains("Feature Builder"))
        #expect(items.map(\.title).contains("Git"))
        #expect(items.map(\.title).contains("Live Git Branch"))

        let selectedKeys = try TerminalChat.parseToolSelection(
            "git live-git-branch",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )

        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featurePackageKey(id: "mlx-git-tools")))
        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featurePackageKey(id: "live-git-branch")))
        #expect(allowedToolNames.contains("git.status"))
        #expect(allowedToolNames.contains("live.git_current_branch"))
    }

    @Test
    func featureBuilderSelectionEnablesLifecycleTools() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-web-tools",
                    source: .bundled,
                    tools: ["web.search"]
                ),
                featureStatus(
                    id: "generated-clock",
                    source: .generated,
                    tools: ["clock.now"]
                )
            ]
        )

        let selectedKeys = try TerminalChat.parseToolSelection(
            "feature-builder",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )
        let renderedSelection = TerminalChat.renderSelectedTools(
            selectedKeys,
            items: items
        )

        #expect(selectedKeys.contains(TerminalToolSelectionCatalog.featureBuilderKey))
        #expect(allowedToolNames.contains("feature.list"))
        #expect(allowedToolNames.contains("feature.enable"))
        #expect(allowedToolNames.contains("feature.disable"))
        #expect(allowedToolNames.contains("feature.scaffold"))
        #expect(!allowedToolNames.contains("web.search"))
        #expect(!allowedToolNames.contains("clock.now"))
        #expect(!allowedToolNames.contains(SwiftFeatureRuntime.featurePackageToolsAllowedName))
        #expect(renderedSelection.contains("Feature Builder"))
    }

    @Test
    func runtimeDiscoveredFeaturePackagesDoNotCountPrefixesAsTools() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "mlx-xcode-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    discoversToolsAtRuntime: true
                ),
                featureStatus(
                    id: "mlx-figma-tools",
                    source: .bundled,
                    tools: ["figma.get_code", "figma.get_variable_defs"],
                    toolNamePrefixes: ["figma."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        let xcodeItem = try #require(items.first { $0.title == "Xcode" })
        let figmaItem = try #require(items.first { $0.title == "Figma" })
        let xcodeDetail = try #require(xcodeItem.detail)
        let figmaDetail = try #require(figmaItem.detail)

        #expect(xcodeDetail.contains("discovers tools at runtime"))
        #expect(!xcodeDetail.contains("1 tool: xcode."))
        #expect(figmaDetail.contains("2 tools: figma.get_code, figma.get_variable_defs"))
    }

    @Test
    func defaultAgentInstructionsDescribeDynamicFeatureWorkflow() {
        let instructions = MLXSystemPromptBuilder.defaultAgentInstructions()

        #expect(instructions.contains("Dynamic Swift feature workflow:"))
        #expect(instructions.contains("feature.scaffold"))
        #expect(instructions.contains("feature.validate"))
        #expect(instructions.contains("feature.build"))
        #expect(instructions.contains("feature.enable"))
        #expect(instructions.contains("feature.reload"))
        #expect(instructions.contains("feature.install"))
        #expect(instructions.contains("Swift tools 6.3"))
        #expect(instructions.contains("core runtime behavior"))
        #expect(instructions.contains("`local.*` file tools"))
        #expect(instructions.contains("`text.*` tools"))
    }

    @Test
    func hostedConfigurationCanReloadAgentProfilesFromStore() throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            cacheAgentProfiles: false,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )

        #expect(configuration.selectedAgent?.displayName == AgentProfileStore.defaultAgentName)
        #expect(configuration.hostedAgentProfiles == nil)
    }

    @Test
    func hostedEffectiveModelUsesHostedManifestInsteadOfCoderSettings() {
        let provider = AgentRemoteProvider(
            name: "mlx-server",
            baseURL: "http://127.0.0.1",
            modelID: "mlx-community/server-model"
        )
        let hostedManifest = AgentSettingsManifest(
            models: [
                AgentSettingsModelManifest(
                    kind: .remoteAPI,
                    modelID: "mlx-community/server-model",
                    provider: provider
                )
            ],
            selectedModelID: "mlx-community/server-model"
        )
        let agent = AgentProfile(
            id: UUID().uuidString,
            name: "Remote default",
            tools: [],
            modelID: "remoteapi:provider:mlx-community/server-model"
        )

        let effectiveModelID = TerminalChat.effectiveModelID(
            selectedAgent: agent,
            manualModelIDOverride: nil,
            manifest: hostedManifest
        )

        #expect(effectiveModelID == "mlx-community/server-model")
    }

    private func featureStatus(
        id: String,
        displayName: String? = nil,
        source: SwiftFeatureBundleSource,
        tools: [String],
        toolNamePrefixes: [String] = [],
        discoversToolsAtRuntime: Bool = false,
        enabled: Bool = true,
        available: Bool = true
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: id,
            displayName: displayName,
            description: nil,
            source: source,
            enabled: enabled,
            available: available,
            executablePath: "/tmp/\(id)",
            manifestPath: nil,
            tools: tools,
            toolNamePrefixes: toolNamePrefixes,
            toolNameAliases: [],
            discoversToolsAtRuntime: discoversToolsAtRuntime,
            build: nil,
            generated: nil,
            issue: nil
        )
    }
}
