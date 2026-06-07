//
//  AgentVoiceTranscriptionService.swift
//  MLXCoder
//

import Foundation

public typealias AgentVoiceTranscriptionProgress = AgentVoiceToolProgress

public struct AgentVoiceAudioInput: Equatable, Sendable {
    public let fileURL: URL
    public let filename: String
    public let contentType: String?
    public let removeAfterUse: Bool

    public init(
        fileURL: URL,
        filename: String? = nil,
        contentType: String? = nil,
        removeAfterUse: Bool = false
    ) {
        self.fileURL = fileURL
        self.filename = filename?.nilIfBlank ?? fileURL.lastPathComponent.nilIfBlank ?? "voice.m4a"
        self.contentType = contentType?.nilIfBlank
        self.removeAfterUse = removeAfterUse
    }

    public func cleanup() {
        guard removeAfterUse else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public actor AgentVoiceTranscriptionService {
    private let settings: AgentVoiceSettingsManifest?

    public init(
        settings: AgentVoiceSettingsManifest? = AgentSettingsManifestStore.load()?.voice
    ) {
        self.settings = settings
    }

    public func transcribe(
        _ audio: AgentVoiceAudioInput,
        progress: AgentVoiceTranscriptionProgress? = nil
    ) async throws -> String {
        defer {
            audio.cleanup()
        }

        guard let settings, settings.isConfigured else {
            throw AgentVoiceTranscriptionError.missingConfiguration
        }
        guard FileManager.default.fileExists(atPath: audio.fileURL.path) else {
            throw AgentVoiceTranscriptionError.missingAudioFile(audio.fileURL.path)
        }

        let result = try await AgentVoiceToolRunner.run(
            executablePath: settings.executablePath,
            arguments: Self.transcriptionArguments(settings: settings, audioURL: audio.fileURL),
            progress: progress
        )
        guard result.exitCode == 0 else {
            throw AgentVoiceTranscriptionError.toolFailed(
                result.exitCode,
                AgentVoiceToolRunner.errorDetail(from: result.stderr)
            )
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw AgentVoiceTranscriptionError.emptyTranscript
        }

        if let data = output.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(LocalVoiceTranscriptionResponse.self, from: data),
           let text = decoded.text.nilIfBlank {
            return text
        }

        throw AgentVoiceTranscriptionError.invalidToolOutput(output)
    }

    public nonisolated static func transcriptionArguments(
        settings: AgentVoiceSettingsManifest,
        audioURL: URL
    ) -> [String] {
        var arguments = [
            "transcribe",
            "--audio",
            audioURL.path,
            "--model",
            settings.transcriptionModelID,
            "--format",
            "json"
        ]
        if let language = settings.language?.nilIfBlank {
            arguments.append(contentsOf: ["--language", language])
        }
        return arguments
    }

    public nonisolated static func voiceProgressMessage(from line: String) -> String? {
        AgentVoiceToolRunner.progressMessage(from: line)
    }
}

public enum AgentVoiceTranscriptionError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case missingAudioFile(String)
    case emptyTranscript
    case invalidToolOutput(String)
    case toolFailed(Int32, String?)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Voice input is not configured. Run mlx-coder --setup and enable voice input."
        case let .missingAudioFile(path):
            return "Voice audio file does not exist: \(path)"
        case .emptyTranscript:
            return "Voice transcription returned no text."
        case let .invalidToolOutput(output):
            return "Voice transcription returned invalid output: \(output)"
        case let .toolFailed(exitCode, detail):
            if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                return "Voice transcription failed with exit code \(exitCode): \(detail)"
            }
            return "Voice transcription failed with exit code \(exitCode)."
        }
    }
}

private struct LocalVoiceTranscriptionResponse: Decodable {
    let text: String
}
