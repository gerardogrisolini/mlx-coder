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
            language: " it ",
            speaker: " Alice "
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
        #expect(configuredSettings.language == "it")
        #expect(configuredSettings.speaker == "Alice")
        #expect(defaultExecutableSettings.isConfigured)
        #expect(defaultExecutableSettings.executablePath == "mlx-voice-transcriber")
        #expect(AgentVoiceSettingsManifest.defaultModelID == "tiny")
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
                language: "it",
                speaker: "Alice"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.voice?.isConfigured == true)
        #expect(decoded.voice?.executablePath == "/opt/mlx/bin/mlx-voice-transcriber")
        #expect(decoded.voice?.modelID == "large-v3-v20240930_626MB")
        #expect(decoded.voice?.language == "it")
        #expect(decoded.voice?.speaker == "Alice")
        #expect(json.contains(#""voice""#))
        #expect(json.contains(#""executablePath""#))
        #expect(!json.contains(#""synthesisModelID""#))
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
        #expect(!disabledCommands.contains("/speak"))
        #expect(enabledCommands.contains("/speak"))
    }

    @Test
    func speakCommandRequiresVoiceSynthesisSupport() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: true,
            voiceSynthesisEnabled: false
        ).map(\.command)

        #expect(commands.contains("/voice"))
        #expect(!commands.contains("/speak"))
    }

    @Test
    func voiceSynthesisSupportIsMacOSOnly() {
        #if os(macOS)
        #expect(AgentVoiceSynthesisService.isSupported)
        #else
        #expect(!AgentVoiceSynthesisService.isSupported)
        #endif
    }

    @Test
    func voiceCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/voice")
                == "mlx-coder: unknown command '/voice'.\n"
        )
        #expect(
            TerminalChat.unknownCommandMessage(for: "/speak")
                == "mlx-coder: unknown command '/speak'.\n"
        )
    }

    @Test
    func submittedLineRoleSeparatesPromptsFromSlashCommands() {
        #expect(TerminalChat.submittedLineRole(for: "ciao") == .prompt)
        #expect(TerminalChat.submittedLineRole(for: "   ") == .empty)
        #expect(TerminalChat.submittedLineRole(for: "/speak") == .slashCommand(token: "/speak"))
        #expect(TerminalChat.submittedLineRole(for: "/help extra") == .slashCommand(token: "/help"))
        #expect(TerminalChat.submittedLineRole(for: "/start 233B0EC4") == .slashCommand(token: "/start"))
    }

    @Test
    func slashCommandsDoNotUsePromptPanelRules() {
        #expect(!TerminalChat.shouldSuspendPanelInput(for: "ciao"))
        #expect(TerminalChat.shouldSuspendPanelInput(for: "/help"))
        #expect(TerminalChat.shouldSuspendPanelInput(for: "/unknown"))
        #expect(!TerminalChat.shouldSuspendPanelInput(for: "/speak"))
        #expect(TerminalChat.isKnownSlashCommand("/session save"))
        #expect(!TerminalChat.isKnownSlashCommand("/start 233B0EC4"))
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
    func voiceProgressMessageUsesOnlyVoiceToolStatusLines() {
        #expect(
            AgentVoiceTranscriptionService.voiceProgressMessage(
                from: "[mlx-voice] Loading speech model tiny..."
            ) == "Loading speech model tiny..."
        )
        #expect(
            AgentVoiceTranscriptionService.voiceProgressMessage(
                from: "WhisperKit internal log"
            ) == nil
        )
        #expect(
            AgentVoiceTranscriptionService.voiceProgressMessage(
                from: "[mlx-voice]   "
            ) == nil
        )
    }

    @Test
    func voiceSynthesisArgumentsUseConfiguredLocalToolLanguageAndVoice() {
        let outputURL = URL(fileURLWithPath: "/tmp/reply.m4a")
        let arguments = AgentVoiceSynthesisService.synthesisArguments(
            settings: AgentVoiceSettingsManifest(
                enabled: true,
                modelID: "tiny",
                executablePath: "/opt/mlx/bin/mlx-voice-transcriber",
                language: "it",
                speaker: "Alice"
            ),
            text: "Ciao",
            outputURL: outputURL
        )

        #expect(arguments == [
            "synthesize",
            "--text",
            "Ciao",
            "--output",
            "/tmp/reply.m4a",
            "--format",
            "m4a",
            "--language",
            "it",
            "--voice",
            "Alice"
        ])
    }

    @Test
    func spokenTextFormatterRemovesCodeBlocksAndShortensLongReplies() {
        let prepared = AgentVoiceSpokenTextFormatter.prepare(
            """
            Ecco il punto principale.

            ```swift
            print("non leggere questo")
            ```

            Questa parte resta parlabile e contiene un link [utile](https://example.com).
            """,
            characterLimit: 160
        )

        #expect(!prepared.text.contains("print"))
        #expect(!prepared.text.contains("example.com"))
        #expect(prepared.text.contains("Ecco il punto principale."))
        #expect(prepared.text.contains("utile"))
    }

    @Test
    func spokenTextFormatterTruncatesAtSpeechBoundary() {
        let longReply = Array(
            repeating: "Questa frase e' pensata per essere abbastanza lunga.",
            count: 40
        ).joined(separator: " ")
        let prepared = AgentVoiceSpokenTextFormatter.prepare(longReply, characterLimit: 220)

        #expect(prepared.isShortened)
        #expect(prepared.text.count <= 220)
        #expect(prepared.text.last == "." || prepared.text.hasSuffix("..."))
    }

    @Test
    func telegramVoiceOriginKeepsChatIDAndMarksVoiceReply() {
        let textOrigin = TerminalPromptOrigin.telegram(chatID: 42)
        let voiceOrigin = TerminalPromptOrigin.telegramVoice(chatID: 42)

        #expect(textOrigin.telegramChatID == 42)
        #expect(voiceOrigin.telegramChatID == 42)
        #expect(!textOrigin.isTelegramVoice)
        #expect(voiceOrigin.isTelegramVoice)
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
