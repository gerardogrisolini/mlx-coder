import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentConfigurationTests {
    @Test
    func shellFilesSearchAndTextToolGroupsAreDistinct() {
        #expect(TerminalToolGroup.group(named: "bash") == .shell)
        #expect(TerminalToolGroup.group(named: "files") == .files)
        #expect(TerminalToolGroup.group(named: "search") == .search)
        #expect(TerminalToolGroup.group(named: "text") == .text)
        #expect(TerminalToolGroup.group(named: "kernel") == .features)

        #expect(TerminalToolGroup.shell.allows(toolName: "local.exec"))
        #expect(!TerminalToolGroup.files.allows(toolName: "local.exec"))
        #expect(TerminalToolGroup.files.allows(toolName: "local.readFile"))
        #expect(!TerminalToolGroup.search.allows(toolName: "local.readFile"))
        #expect(TerminalToolGroup.search.allows(toolName: "search.grep"))
        #expect(TerminalToolGroup.text.allows(toolName: "text.wc"))
        #expect(TerminalToolGroup.features.allows(toolName: "feature.list"))
    }

    @Test
    func defaultAgentProfilesEnableSplitLocalToolGroups() {
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
        #expect(allowedToolNames.contains(SwiftFeatureRuntime.generatedFeatureToolsAllowedName))
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
}
