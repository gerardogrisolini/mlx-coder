import MLXCoderCore
@testable import MLXCoderSetup
import Testing

@Suite
struct MLXCoderAgentProfileSetupRunnerTests {
    @Test
    func setupPreparationRemovesRetiredRecommendedAgentsAndAddsMinimal() throws {
        let oldDefaultAgents = [
            AgentProfile(
                id: AgentProfileStore.defaultAgentID.uuidString,
                name: "Default",
                tools: AgentProfileStore.defaultToolNames
            ),
            AgentProfile(
                id: "00000000-0000-0000-0000-000000000003",
                name: "Feature",
                tools: AgentProfileStore.defaultToolNames
            ),
            AgentProfile(
                id: AgentProfileStore.builderAgentID.uuidString,
                name: AgentProfileStore.builderAgentName,
                tools: AgentProfileStore.builderToolNames
            ),
            AgentProfile(
                id: "00000000-0000-0000-0000-000000000005",
                name: "Research",
                tools: AgentProfileStore.defaultToolNames
            )
        ]

        let prepared = MLXCoderAgentProfileSetupRunner.preparedAgentsForSave(oldDefaultAgents)
        let names = Set(prepared.map(\.name))
        let minimal = try #require(prepared.first { $0.name == "Minimal" })

        #expect(names.contains("Default"))
        #expect(names.contains("Minimal"))
        #expect(names.contains("Builder"))
        #expect(!names.contains("Feature"))
        #expect(!names.contains("Research"))
        #expect(minimal.tools == AgentProfileStore.minimalToolNames)
    }

    @Test
    func setupRecommendedAgentCountMatchesDefaultProfiles() {
        #expect(
            MLXCoderAgentProfileSetupRunner.recommendedAgentCount
                == AgentProfileStore.defaultProfiles().count
        )
    }
}
