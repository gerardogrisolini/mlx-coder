import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentTelegramControlRuntimeTests {
    @Test
    func manifestRoundTripsTelegramTokenInSettings() throws {
        let manifest = AgentSettingsManifest(
            models: [
                AgentSettingsModelManifest(
                    kind: .remoteAPI,
                    modelID: "test-model",
                    provider: AgentRemoteProvider(modelID: "test-model")
                )
            ],
            selectedModelID: "test-model",
            telegramBotToken: "123456:telegram-token"
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)

        #expect(decoded.telegramBotToken == "123456:telegram-token")
    }

    @Test
    func plainTelegramMessagesUseDefaultAgent() {
        let command = AgentTelegramPromptParser.promptCommand(from: "continua")

        #expect(command?.agentToken == nil)
        #expect(command?.prompt == "continua")
    }

    @Test
    func telegramSlashAgentCommandRoutesPrompt() {
        let command = AgentTelegramPromptParser.promptCommand(from: "/Review controlla i test")

        #expect(command?.agentToken == "Review")
        #expect(command?.prompt == "controlla i test")
    }

    @Test
    func reservedSlashCommandsStayAsRemoteCommands() {
        let command = AgentTelegramPromptParser.promptCommand(from: "/status")

        #expect(command?.agentToken == nil)
        #expect(command?.prompt == "/status")
    }
}
