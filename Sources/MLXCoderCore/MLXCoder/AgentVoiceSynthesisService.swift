//
//  AgentVoiceSynthesisService.swift
//  MLXCoder
//

import Foundation

public typealias AgentVoiceSynthesisProgress = AgentVoiceToolProgress

public struct AgentVoiceSpokenText: Equatable, Sendable {
    public let text: String
    public let isShortened: Bool
}

public enum AgentVoiceSpokenTextFormatter {
    public static let defaultCharacterLimit = 1_200

    public static func prepare(
        _ text: String,
        characterLimit: Int = Self.defaultCharacterLimit
    ) -> AgentVoiceSpokenText {
        let normalizedOriginal = normalizedSpeechText(text)
        let speechText = normalizedSpeechText(
            removeMarkdownNoise(from: text)
        ).nilIfBlank ?? normalizedOriginal
        let limit = max(80, characterLimit)
        guard speechText.count > limit else {
            return AgentVoiceSpokenText(text: speechText, isShortened: speechText != normalizedOriginal)
        }

        return AgentVoiceSpokenText(
            text: truncatedAtSpeechBoundary(speechText, limit: limit),
            isShortened: true
        )
    }

    private static func removeMarkdownNoise(from text: String) -> String {
        var outputLines: [String] = []
        var isInsideCodeBlock = false
        for line in text.components(separatedBy: .newlines) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                isInsideCodeBlock.toggle()
                continue
            }
            guard !isInsideCodeBlock else {
                continue
            }
            outputLines.append(line)
        }

        var cleaned = outputLines.joined(separator: "\n")
        cleaned = cleaned.replacingOccurrences(
            of: #"\[([^\]]+)\]\([^)]+\)"#,
            with: "$1",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"https?://\S+"#,
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "`", with: "")
        return cleaned
    }

    private static func normalizedSpeechText(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map(cleanSpeechLine)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSpeechLine(_ line: String) -> String {
        var cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix("#") {
            cleaned.removeFirst()
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for marker in ["- ", "* ", "+ ", "> "] where cleaned.hasPrefix(marker) {
            cleaned.removeFirst(marker.count)
            break
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func truncatedAtSpeechBoundary(_ text: String, limit: Int) -> String {
        let limitIndex = text.index(text.startIndex, offsetBy: limit)
        let prefix = text[..<limitIndex]
        let minimumBoundaryDistance = limit / 2
        let boundaryIndex = prefix.indices.reversed().first { index in
            let distance = text.distance(from: text.startIndex, to: index)
            guard distance >= minimumBoundaryDistance else {
                return false
            }
            return ".!?".contains(prefix[index])
        } ?? prefix.indices.reversed().first { index in
            let distance = text.distance(from: text.startIndex, to: index)
            return distance >= minimumBoundaryDistance && prefix[index].isWhitespace
        }

        let truncated: String
        if let boundaryIndex {
            let endIndex = text.index(after: boundaryIndex)
            truncated = String(text[..<endIndex])
        } else {
            truncated = String(prefix)
        }
        let trimmed = truncated.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.last.map({ ".!?".contains($0) }) == true {
            return trimmed
        }
        return "\(trimmed)..."
    }
}

public struct AgentVoiceSynthesisOutput: Equatable, Sendable {
    public let fileURL: URL
    public let filename: String
    public let contentType: String
    public let removeAfterUse: Bool

    public init(
        fileURL: URL,
        filename: String? = nil,
        contentType: String = "audio/mp4",
        removeAfterUse: Bool = false
    ) {
        self.fileURL = fileURL
        self.filename = filename?.nilIfBlank ?? fileURL.lastPathComponent.nilIfBlank ?? "speech.m4a"
        self.contentType = contentType
        self.removeAfterUse = removeAfterUse
    }

    public func cleanup() {
        guard removeAfterUse else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}

public actor AgentVoiceSynthesisService {
    private let settings: AgentVoiceSettingsManifest?

    public nonisolated static var isSupported: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    public init(
        settings: AgentVoiceSettingsManifest? = AgentSettingsManifestStore.load()?.voice
    ) {
        self.settings = settings
    }

    public func synthesize(
        _ text: String,
        progress: AgentVoiceSynthesisProgress? = nil
    ) async throws -> AgentVoiceSynthesisOutput {
        let speechText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !speechText.isEmpty else {
            throw AgentVoiceSynthesisError.emptyText
        }
        guard Self.isSupported else {
            throw AgentVoiceSynthesisError.unsupportedPlatform
        }
        guard let settings, settings.isConfigured else {
            throw AgentVoiceSynthesisError.missingConfiguration
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-speech-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let result = try await AgentVoiceToolRunner.run(
            executablePath: settings.executablePath,
            arguments: Self.synthesisArguments(
                settings: settings,
                text: speechText,
                outputURL: outputURL
            ),
            progress: progress
        )
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw AgentVoiceSynthesisError.toolFailed(
                result.exitCode,
                AgentVoiceToolRunner.errorDetail(from: result.stderr)
            )
        }

        let producedURL = Self.producedAudioURL(from: result.stdout) ?? outputURL
        guard FileManager.default.fileExists(atPath: producedURL.path) else {
            throw AgentVoiceSynthesisError.missingOutput(producedURL.path)
        }
        return AgentVoiceSynthesisOutput(
            fileURL: producedURL,
            filename: producedURL.lastPathComponent,
            contentType: Self.contentType(for: producedURL),
            removeAfterUse: true
        )
    }

    public nonisolated static func synthesisArguments(
        settings: AgentVoiceSettingsManifest,
        text: String,
        outputURL: URL
    ) -> [String] {
        var arguments = [
            "synthesize",
            "--text",
            text,
            "--output",
            outputURL.path,
            "--format",
            outputURL.pathExtension.nilIfBlank ?? "m4a"
        ]
        if let language = settings.language?.nilIfBlank {
            arguments.append(contentsOf: ["--language", language])
        }
        if let speaker = settings.speaker?.nilIfBlank {
            arguments.append(contentsOf: ["--voice", speaker])
        }
        return arguments
    }

    private nonisolated static func producedAudioURL(from output: String) -> URL? {
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedOutput.data(using: .utf8),
              let response = try? JSONDecoder().decode(LocalVoiceSynthesisResponse.self, from: data),
              let audioPath = response.audioPath.nilIfBlank else {
            return nil
        }
        return URL(fileURLWithPath: audioPath)
    }

    private nonisolated static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        default:
            return "application/octet-stream"
        }
    }
}

public enum AgentVoiceSynthesisError: LocalizedError, Sendable, Equatable {
    case unsupportedPlatform
    case missingConfiguration
    case emptyText
    case missingOutput(String)
    case toolFailed(Int32, String?)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Voice output is available only on macOS."
        case .missingConfiguration:
            return "Voice output is not configured. Run mlx-coder --setup and enable voice tools."
        case .emptyText:
            return "Voice output needs text to speak."
        case let .missingOutput(path):
            return "Voice synthesis did not produce an audio file: \(path)"
        case let .toolFailed(exitCode, detail):
            if let detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines),
               !detail.isEmpty {
                return "Voice synthesis failed with exit code \(exitCode): \(detail)"
            }
            return "Voice synthesis failed with exit code \(exitCode)."
        }
    }
}

private struct LocalVoiceSynthesisResponse: Decodable {
    let audioPath: String
}
