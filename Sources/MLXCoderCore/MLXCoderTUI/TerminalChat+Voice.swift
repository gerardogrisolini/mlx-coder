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
            interactiveReader.setPanelProcessing(true)
            interactiveReader.setPanelModeOverride(
                TerminalPanelModeOverride(
                    modeText: "Recording voice",
                    helpText: "Press Enter to stop · Esc cancel"
                )
            )
            writeSystemMessage("Recording voice. Press Enter to stop.\n")
        } catch {
            clearVoicePanelMode()
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
            interactiveReader.setPanelModeOverride(
                TerminalPanelModeOverride(
                    modeText: "Transcribing voice",
                    helpText: "Please wait"
                )
            )
            writeSystemMessage("Transcribing voice...\n")
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
                .transcribe(audio)
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
        interactiveReader.setPanelModeOverride(nil)
        interactiveReader.setPanelProcessing(false)
    }

    func transcribeVoiceAudio(
        _ audio: AgentVoiceAudioInput,
        origin: TerminalPromptOrigin,
        eventQueue: TerminalChatEventQueue
    ) -> Task<Void, Never> {
        Task {
            do {
                let transcript = try await AgentVoiceTranscriptionService()
                    .transcribe(audio)
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
}
