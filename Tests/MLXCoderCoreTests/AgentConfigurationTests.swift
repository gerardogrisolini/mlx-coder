import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentConfigurationTests {
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
