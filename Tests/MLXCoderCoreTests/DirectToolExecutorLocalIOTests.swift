import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct DirectToolExecutorLocalIOTests {
    @Test
    func baseCatalogKeepsCoreLocalAndTextToolsOnly() {
        let baseToolNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        let selectableToolNames = Set(AgentToolSelection.selectableDescriptors().map(\.name))

        #expect(baseToolNames.contains("local.exec"))
        #expect(baseToolNames.contains("local.readFile"))
        #expect(baseToolNames.contains("local.writeFile"))
        #expect(baseToolNames.contains("text.wc"))
        #expect(baseToolNames.contains("feature.list"))
        #expect(baseToolNames.contains("feature.enable"))
        #expect(baseToolNames.contains("feature.delete"))
        #expect(!baseToolNames.contains("search.glob"))
        #expect(!baseToolNames.contains("web.search"))
        #expect(!baseToolNames.contains("git.status"))

        #expect(selectableToolNames.contains("local.readFile"))
        #expect(selectableToolNames.contains("local.writeFile"))
        #expect(selectableToolNames.contains("search.glob"))
        #expect(selectableToolNames.contains("text.wc"))
        #expect(selectableToolNames.contains("web.search"))
        #expect(selectableToolNames.contains("git.status"))
    }
}

private actor TestAgentRuntimeBackend: AgentRuntimeBackend {
    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test"
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
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test")
    }
}
