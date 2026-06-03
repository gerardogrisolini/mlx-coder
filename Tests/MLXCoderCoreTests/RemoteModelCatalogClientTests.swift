import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct RemoteModelCatalogClientTests {
    @Test
    func detectsThinkingParametersFromMLXServerModelMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "mlx-community/qwen3-test",
                "thinking": [
                    "supports_thinking": true,
                    "supports_reasoning_effort": true,
                    "supports_preserve_thinking": true,
                    "available_selections": ["off", "low", "medium", "high"],
                    "default_selection": "medium"
                ]
            ],
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "mlx-community/qwen3-test"
        )

        #expect(support?.supportsThinking == true)
        #expect(support?.supportsReasoningEffort == true)
        #expect(support?.supportsPreserveThinking == true)
        #expect(support?.availableSelections == [.off, .low, .medium, .high])
        #expect(support?.defaultSelection == .medium)

        let manifest = AgentSettingsModelManifestFactory.remoteAPIModel(
            title: "Qwen3 Test",
            modelID: "mlx-community/qwen3-test",
            providerID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
            providerName: "Modal",
            baseURL: "https://api.us-west-2.modal.direct/v1",
            chatEndpoint: .chatCompletions,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSupport: support
        )

        #expect(manifest.availableThinkingSelections == [.off, .low, .medium, .high])
        #expect(manifest.resolvedDefaultThinkingSelection == .medium)
    }

    @Test
    func infersThinkingForSparseNVIDIANemotronCatalogIDs() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "nvidia/llama-3.3-nemotron-super-49b-v1"
            ],
            baseURL: "https://integrate.api.nvidia.com/v1",
            modelID: "nvidia/llama-3.3-nemotron-super-49b-v1"
        )

        #expect(support?.supportsThinking == true)
        #expect(support?.supportsReasoningEffort == false)
        #expect(support?.availableSelections == [.enabled, .off])
        #expect(support?.defaultSelection == .enabled)
    }

    @Test
    func doesNotInferThinkingForSparseNonReasoningNVIDIAModels() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "meta/llama-3.3-70b-instruct"
            ],
            baseURL: "https://integrate.api.nvidia.com/v1",
            modelID: "meta/llama-3.3-70b-instruct"
        )

        #expect(support == nil)
    }

    @Test
    func fallsBackToGenericThinkingForModalDirectModelsWithoutMetadata() {
        let support = RemoteModelCatalogClient.thinkingSupport(
            fromModelMetadata: [
                "id": "zai-org/GLM-5.1-FP8"
            ],
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "zai-org/GLM-5.1-FP8"
        )

        #expect(support?.supportsThinking == true)
        #expect(support?.supportsReasoningEffort == false)
        #expect(support?.availableSelections == [.enabled, .off])
        #expect(support?.defaultSelection == .enabled)
    }

    @Test
    func modalDirectProvidersRequireAPIKeys() {
        let provider = AgentRemoteProvider(
            name: "Modal",
            baseURL: "https://api.us-west-2.modal.direct/v1",
            modelID: "mlx-community/qwen3-test"
        )

        #expect(provider.requiresAPIKey)
    }
}
