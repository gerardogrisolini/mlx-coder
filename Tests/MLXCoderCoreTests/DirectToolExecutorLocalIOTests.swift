import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct DirectToolExecutorLocalIOTests {
    @Test
    func globTreatsExistingDirectoryPatternAsSearchRoot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-direct-tool-glob-tests-\(UUID().uuidString)", isDirectory: true)
        let sourcesURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let nestedURL = sourcesURL.appendingPathComponent("Nested", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )
        try "struct A {}".write(
            to: sourcesURL.appendingPathComponent("A.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "struct B {}".write(
            to: nestedURL.appendingPathComponent("B.swift"),
            atomically: true,
            encoding: .utf8
        )

        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            subAgentBackendFactory: { TestAgentRuntimeBackend() }
        )
        let toolCall = DirectAgentToolCall(
            id: "tool-call-1",
            name: "search.glob",
            argumentsObject: [
                "pattern": sourcesURL.path,
                "maxResults": 20
            ],
            argumentsJSON: #"{"pattern":"\#(sourcesURL.path)","maxResults":20}"#
        )

        let result = await executor.execute(
            sessionID: "test-session",
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["search."]
        )

        #expect(result.output.contains("A.swift"))
        #expect(result.output.contains("Nested/B.swift"))
        #expect(!result.output.contains("<empty>"))
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
