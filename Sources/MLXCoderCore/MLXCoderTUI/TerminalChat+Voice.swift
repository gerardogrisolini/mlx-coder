//
//  TerminalChat+Voice.swift
//  mlx-coder
//

import Foundation

extension TerminalChat {
    func handleVoiceCommand(_ command: String) async {
        let argument = String(command.dropFirst("/voice".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard argument.isEmpty else {
            writeSystemMessage("Usage: /voice\n")
            return
        }

        guard stdinIsTerminal else {
            writeFailureMessage("mlx-coder: /voice requires the interactive TUI.\n")
            return
        }

        guard activeVoiceRecordingSession == nil else {
            writeSystemMessage("Voice recording is already active. Press Enter to stop.\n")
            return
        }

        do {
            activeVoiceRecordingSession = try await voiceRecordingService.startRecording()
            interactiveReader.setPanelText("")
            interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Recording voice",
                    helpText: "Press Enter to stop · Esc cancel"
                ),
                isProcessing: true
            )
        } catch {
            clearVoicePanelMode()
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    func handleSpeakCommand(_ command: String) async {
        let argument = String(command.dropFirst("/speak".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard argument.isEmpty else {
            writeSystemMessage("Usage: /speak\n")
            return
        }

        guard stdinIsTerminal else {
            writeFailureMessage("mlx-coder: /speak requires the interactive TUI.\n")
            return
        }

        guard let text = lastAssistantResponseText?.nilIfBlank else {
            writeFailureMessage("mlx-coder: no assistant response to speak.\n")
            return
        }

        do {
            interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Speaking response",
                    helpText: "Synthesizing audio"
                ),
                isProcessing: true
            )
            defer {
                interactiveReader.setPanelOverlay(nil, isProcessing: false)
            }

            let spokenText = AgentVoiceSpokenTextFormatter.prepare(text)
            let audio = try await AgentVoiceSynthesisService()
                .synthesize(spokenText.text)
            defer {
                audio.cleanup()
            }
            interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Speaking response",
                    helpText: "Playing audio"
                ),
                isProcessing: true
            )
            try await playSynthesizedAudio(at: audio.fileURL)
        } catch {
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    func stopVoiceRecordingAndTranscribe(
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        do {
            let audio = try voiceRecordingService.stopRecording()
            activeVoiceRecordingSession = nil
            interactiveReader.setPanelText("")
            interactiveReader.setPanelOverlay(
                TerminalPanelModeOverride(
                    modeText: "Transcribing voice",
                    helpText: "Please wait"
                ),
                isProcessing: true
            )
            return transcribeVoiceAudio(audio, origin: .local, eventQueue: eventQueue)
        } catch {
            activeVoiceRecordingSession = nil
            clearVoicePanelMode()
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
            return Task {}
        }
    }

    func cancelVoiceRecording() {
        activeVoiceRecordingSession = nil
        voiceRecordingService.cancelRecording()
        clearVoicePanelMode()
        writeSystemMessage("Voice recording cancelled.\n")
    }

    func stopVoiceRecordingAndRunPromptBlocking() async {
        do {
            let audio = try voiceRecordingService.stopRecording()
            activeVoiceRecordingSession = nil
            writeSystemMessage("Transcribing voice...\n")
            let transcript = try await AgentVoiceTranscriptionService()
                .transcribe(audio) { message in
                    self.writeSystemMessage("Voice: \(message)\n")
                }
            let prompt = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else {
                writeFailureMessage("mlx-coder: Voice transcription returned no text.\n")
                return
            }
            writeSubmittedPrompt(prompt)
            await runPromptBlocking(promptAttempt(prompt: prompt))
        } catch {
            activeVoiceRecordingSession = nil
            clearVoicePanelMode()
            writeFailureMessage("mlx-coder: \(error.localizedDescription)\n")
        }
    }

    func clearVoicePanelMode() {
        interactiveReader.setPanelOverlay(nil, isProcessing: false)
    }

    func transcribeVoiceAudio(
        _ audio: AgentVoiceAudioInput,
        origin: TerminalPromptOrigin,
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        Task {
            do {
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio) { message in
                        await eventQueue.send(
                            .voicePromptProgress(
                                TerminalVoicePromptProgress(
                                    origin: origin,
                                    message: message
                                )
                            )
                        )
                    }
                await eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: origin,
                            outcome: .success(transcript)
                        )
                    )
                )
            } catch is CancellationError {
                return
            } catch {
                await eventQueue.send(
                    .voicePromptCompleted(
                        TerminalVoicePromptResult(
                            origin: origin,
                            outcome: .failure(error.localizedDescription)
                        )
                    )
                )
            }
        }
    }

    private func playSynthesizedAudio(at url: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let afplayURL = URL(fileURLWithPath: "/usr/bin/afplay")
            guard FileManager.default.isExecutableFile(atPath: afplayURL.path) else {
                throw TerminalVoicePlaybackError.afplayUnavailable
            }
            let process = Process()
            process.executableURL = afplayURL
            process.arguments = [url.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw TerminalVoicePlaybackError.playbackFailed(process.terminationStatus)
            }
        }.value
    }
}

private enum TerminalVoicePlaybackError: LocalizedError {
    case afplayUnavailable
    case playbackFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .afplayUnavailable:
            return "Audio playback requires /usr/bin/afplay on macOS."
        case let .playbackFailed(exitCode):
            return "Audio playback failed with exit code \(exitCode)."
        }
    }
}
