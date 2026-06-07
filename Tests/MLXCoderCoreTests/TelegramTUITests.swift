@testable import MLXCoderCore
import Foundation
import Testing

@Suite
struct TelegramTUITests {
    @Test
    func telegramSettingsRequireEnabledToken() {
        let tokenOnlySettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " 123456:ABCDEF "
        )
        let pairedSettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " 123456:ABCDEF ",
            linkedChatID: 42,
            linkedChatTitle: "Gerardo"
        )
        let missingTokenSettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " "
        )
        let disabledSettings = AgentTelegramSettingsManifest(
            enabled: false,
            botToken: "123456:ABCDEF"
        )

        #expect(tokenOnlySettings.isConfigured)
        #expect(!tokenOnlySettings.isEnabled)
        #expect(tokenOnlySettings.botToken == "123456:ABCDEF")
        #expect(pairedSettings.isConfigured)
        #expect(pairedSettings.isEnabled)
        #expect(pairedSettings.linkedChatID == 42)
        #expect(pairedSettings.linkedChatTitle == "Gerardo")
        #expect(!missingTokenSettings.isEnabled)
        #expect(missingTokenSettings.botToken == nil)
        #expect(!disabledSettings.isEnabled)
        #expect(disabledSettings.botToken == nil)
    }

    @Test
    func settingsManifestRoundTripsEnabledTelegramConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF",
                linkedChatID: 42,
                linkedChatTitle: "Gerardo"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.telegram?.isEnabled == true)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == 42)
        #expect(decoded.telegram?.linkedChatTitle == "Gerardo")
        #expect(json.contains(#""telegram""#))
        #expect(json.contains(#""botToken":"123456:ABCDEF""#))
        #expect(json.contains(#""linkedChatID":42"#))
    }

    @Test
    func settingsManifestPreservesTokenOnlyTelegramConfigurationWithoutEnablingCommand() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)

        #expect(decoded.telegram?.isConfigured == true)
        #expect(decoded.telegram?.isEnabled == false)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == nil)
    }

    @Test
    func settingsManifestOmitsDisabledTelegramConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: false,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.telegram == nil)
        #expect(!json.contains(#""telegram""#))
    }

    @Test
    func telegramCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: true,
            voiceEnabled: false
        ).map(\.command)

        #expect(!disabledCommands.contains("/telegram"))
        #expect(enabledCommands.contains("/telegram"))
    }

    @Test
    func builderCommandVisibilityRemainsIndependentFromTelegram() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: true,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)

        #expect(commands.contains("/feature"))
        #expect(!commands.contains("/telegram"))
    }

    @Test
    func telegramCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/telegram on")
                == "mlx-coder: unknown command '/telegram'.\n"
        )
    }

    @Test
    func voiceSettingsRequireEnabledLocalExecutable() {
        let configuredSettings = AgentVoiceSettingsManifest(
            enabled: true,
            modelID: " large-v3-v20240930_626MB ",
            executablePath: " /usr/local/bin/mlx-voice-transcriber ",
            synthesisModelID: " 0.6b ",
            language: " it ",
            speaker: " ryan "
        )
        let defaultExecutableSettings = AgentVoiceSettingsManifest(
            enabled: true,
            modelID: " tiny "
        )
        let disabledSettings = AgentVoiceSettingsManifest(
            enabled: false,
            modelID: "tiny",
            executablePath: "/usr/local/bin/mlx-voice-transcriber"
        )

        #expect(configuredSettings.isConfigured)
        #expect(configuredSettings.executablePath == "/usr/local/bin/mlx-voice-transcriber")
        #expect(configuredSettings.modelID == "large-v3-v20240930_626MB")
        #expect(configuredSettings.synthesisModelID == "0.6b")
        #expect(configuredSettings.language == "it")
        #expect(configuredSettings.speaker == "ryan")
        #expect(defaultExecutableSettings.isConfigured)
        #expect(defaultExecutableSettings.executablePath == "mlx-voice-transcriber")
        #expect(!disabledSettings.isConfigured)
    }

    @Test
    func settingsManifestRoundTripsVoiceConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            voice: AgentVoiceSettingsManifest(
                enabled: true,
                modelID: "large-v3-v20240930_626MB",
                executablePath: "/opt/mlx/bin/mlx-voice-transcriber",
                synthesisModelID: "1.7b",
                language: "it",
                speaker: "serena"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.voice?.isConfigured == true)
        #expect(decoded.voice?.executablePath == "/opt/mlx/bin/mlx-voice-transcriber")
        #expect(decoded.voice?.modelID == "large-v3-v20240930_626MB")
        #expect(decoded.voice?.synthesisModelID == "1.7b")
        #expect(decoded.voice?.language == "it")
        #expect(decoded.voice?.speaker == "serena")
        #expect(json.contains(#""voice""#))
        #expect(json.contains(#""executablePath""#))
        #expect(json.contains("mlx-voice-transcriber"))
    }

    @Test
    func voiceSettingsDecodeLegacyOpenAIConfigurationAsLocalDefaults() throws {
        let data = Data(
            """
            {
              "version": 9,
              "models": [],
              "voice": {
                "enabled": true,
                "provider": "openai",
                "apiKey": "sk-test",
                "modelID": "legacy-cloud-transcribe"
              }
            }
            """.utf8
        )

        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)

        #expect(decoded.voice?.isConfigured == true)
        #expect(decoded.voice?.provider == .local)
        #expect(decoded.voice?.executablePath == "mlx-voice-transcriber")
        #expect(decoded.voice?.modelID == AgentVoiceSettingsManifest.defaultModelID)
    }

    @Test
    func voiceCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: true
        ).map(\.command)

        #expect(!disabledCommands.contains("/voice"))
        #expect(enabledCommands.contains("/voice"))
    }

    @Test
    func voiceCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/voice")
                == "mlx-coder: unknown command '/voice'.\n"
        )
    }

    @Test
    func voiceTranscriptionArgumentsUseConfiguredLocalToolModelAndLanguage() throws {
        let audioURL = URL(fileURLWithPath: "/tmp/voice.m4a")
        let arguments = AgentVoiceTranscriptionService.transcriptionArguments(
            settings: AgentVoiceSettingsManifest(
                enabled: true,
                modelID: "large-v3-v20240930_626MB",
                executablePath: "/opt/mlx/bin/mlx-voice-transcriber",
                language: "it"
            ),
            audioURL: audioURL
        )

        #expect(arguments == [
            "transcribe",
            "--audio",
            "/tmp/voice.m4a",
            "--model",
            "large-v3-v20240930_626MB",
            "--format",
            "json",
            "--language",
            "it"
        ])
    }

    @Test
    func telegramCommandActionAcceptsOnlyOnOffAndBareStatus() {
        #expect(TerminalTelegramCommandAction(argument: "") == .status)
        #expect(TerminalTelegramCommandAction(argument: " on ") == .turnOn)
        #expect(TerminalTelegramCommandAction(argument: "off") == .turnOff)
        #expect(TerminalTelegramCommandAction(argument: "status") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "start") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "stop") == .usage)
    }

    @Test
    func telegramStartPayloadIsRemoteCommandNotPrompt() {
        #expect(TerminalTelegramRemoteCommand(text: "/start") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start@mlx_coder_bot 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/help") == .help)
        #expect(TerminalTelegramRemoteCommand(text: "ciao") == nil)
    }

    @Test
    func telegramProgressReporterRequiresActiveTelegramSession() throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.telegramLinkedChatID = 42

        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: false,
            statusText: "Configured",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 42)) == nil)

        terminal.telegramControlState.isActive = true
        #expect(terminal.makeTelegramTurnProgressReporter(for: .local) == nil)
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 43)) == nil)
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 42)) != nil)
    }

    @Test
    func telegramPairingCodeAcceptsPlainCodeAndStartPayload() {
        #expect(TerminalTelegramPairingService.pairingCode(in: " abcd1234 ") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start abcd1234") == "ABCD1234")
        #expect(
            TerminalTelegramPairingService.pairingCode(in: "/start@mlx_coder_bot abcd1234")
                == "ABCD1234"
        )
        #expect(TerminalTelegramPairingService.pairingCode(in: "\n/start AbCd1234\n") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start") == nil)
    }
}
