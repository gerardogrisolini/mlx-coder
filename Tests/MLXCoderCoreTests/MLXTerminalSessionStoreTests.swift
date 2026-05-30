import Foundation
@testable import MLXCoderCore
import Testing

@Suite(.serialized)
struct MLXTerminalSessionStoreTests {
    @Test
    func savesBinarySessionForProject() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let projectURL = supportDirectory
            .appendingPathComponent("Project A", isDirectory: true)
        let session = sampleSession(
            name: "daily checkpoint",
            workingDirectory: projectURL
        )

        let fileURL = try MLXTerminalSessionStore.save(
            session,
            supportDirectoryURL: supportDirectory
        )
        let storedData = try Data(contentsOf: fileURL)
        let storedPrefix = String(
            data: storedData.prefix(6),
            encoding: .utf8
        )

        #expect(fileURL.pathExtension == MLXTerminalSessionStore.fileExtension)
        #expect(storedPrefix == "bplist")
        #expect(try MLXTerminalSessionStore.load(from: fileURL) == session)
    }

    @Test
    func listsOnlySessionsForRequestedProject() throws {
        let supportDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        let firstProject = supportDirectory
            .appendingPathComponent("First", isDirectory: true)
        let secondProject = supportDirectory
            .appendingPathComponent("Second", isDirectory: true)

        let firstSession = sampleSession(
            name: "first",
            workingDirectory: firstProject
        )
        let secondSession = sampleSession(
            name: "second",
            workingDirectory: secondProject
        )
        _ = try MLXTerminalSessionStore.save(
            firstSession,
            supportDirectoryURL: supportDirectory
        )
        _ = try MLXTerminalSessionStore.save(
            secondSession,
            supportDirectoryURL: supportDirectory
        )

        let listedSessions = try MLXTerminalSessionStore.savedSessions(
            for: firstProject,
            supportDirectoryURL: supportDirectory
        )

        #expect(listedSessions.map(\.name) == ["first"])
    }

    @Test
    func filenameStemSanitizesSessionName() {
        #expect(
            MLXTerminalSessionStore.filenameStem(for: " daily/checkpoint ") == "daily_checkpoint"
        )
        #expect(MLXTerminalSessionStore.filenameStem(for: "///") == "session")
    }

    private func sampleSession(
        name: String,
        workingDirectory: URL
    ) -> MLXTerminalSavedSession {
        MLXTerminalSavedSession(
            name: name,
            sessionID: "terminal-test",
            cacheKey: "cache-test",
            workingDirectoryPath: workingDirectory.path,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 20),
            modelID: "model-test",
            agentID: "default",
            agentName: "Default",
            selectedToolGroups: ["bash", "git"],
            selectedSkillIDs: ["skill-a"],
            thinkingSelection: "on",
            systemPrompt: "System",
            history: [
                AgentRuntimeMessage(role: .user, content: "ciao"),
                AgentRuntimeMessage(
                    role: .assistant,
                    content: "",
                    toolCalls: [
                        AgentRuntimeToolCall(
                            id: "call_1",
                            name: "local.exec",
                            argumentsJSON: #"{"command":"pwd"}"#
                        )
                    ]
                ),
                AgentRuntimeMessage(
                    role: .tool,
                    content: "/tmp",
                    toolCallID: "call_1"
                )
            ]
        )
    }

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "mlx-terminal-session-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
    }
}
