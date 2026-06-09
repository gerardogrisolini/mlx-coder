import Foundation
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

    @Test
    func setupDefaultThinkingSelectionKeepsCompatibleExistingValue() {
        let model = setupThinkingModel()

        let selection = MLXCoderSetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .high
        )

        #expect(selection == .high)
    }

    @Test
    func setupDefaultThinkingSelectionFallsBackToModelDefault() {
        let model = setupThinkingModel()

        let selection = MLXCoderSetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .xhigh
        )

        #expect(selection == .medium)
    }

    @Test
    func setupDefaultThinkingSelectionSkipsModelsWithoutThinking() {
        let model = AgentSettingsModelManifest(
            id: "plain",
            kind: .remoteAPI,
            modelID: "plain-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "plain-model")
        )

        let selection = MLXCoderSetupRunner.setupDefaultThinkingSelection(
            for: model,
            existingSelection: .high
        )

        #expect(selection == nil)
    }

    @Test
    func skillCheckboxItemsPreserveMissingSelectedSkills() {
        let skill = MLXPromptSkill(
            canonicalName: "swift-review",
            title: "Swift Review",
            summary: "Review Swift code.",
            promptBody: "Review the code.",
            sourceHash: "skill-a"
        )

        let items = MLXCoderAgentProfileSetupRunner.skillCheckboxItems(
            availableSkills: [skill],
            selectedSkillIDs: ["skill-a", "missing-skill"]
        )

        #expect(items.map(\.value) == ["skill-a", "missing-skill"])
        #expect(items.last?.detail == "saved skill not currently installed")
    }

    @Test
    func thinkingSelectionItemsUseMenuTitles() {
        let items = MLXCoderAgentProfileSetupRunner.thinkingSelectionItems([.off, .high])

        #expect(items.map(\.value) == [.off, .high])
        #expect(items.map(\.title) == ["Thinking off", "High thinking"])
    }

    private func setupThinkingModel() -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: "thinking",
            kind: .remoteAPI,
            modelID: "thinking-model",
            providerID: UUID(),
            provider: AgentRemoteProvider(modelID: "thinking-model"),
            thinkingOptions: [.off, .low, .medium, .high],
            defaultThinkingSelection: .medium
        )
    }
}
