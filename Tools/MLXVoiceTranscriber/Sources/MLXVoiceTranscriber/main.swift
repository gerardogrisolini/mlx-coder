//
//  main.swift
//  mlx-voice-transcriber
//

import Darwin
import Foundation
import TTSKit
import WhisperKit

@main
struct MLXVoiceTranscriberMain {
    static func main() async {
        do {
            let command = try VoiceCommand(arguments: Array(CommandLine.arguments.dropFirst()))
            switch command {
            case let .transcribe(options):
                try await transcribe(options)
            case let .synthesize(options):
                try await synthesize(options)
            case .help:
                print(Self.usage)
            }
        } catch {
            FileHandle.standardError.write(Data("mlx-voice-transcriber: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func transcribe(_ options: TranscribeOptions) async throws {
        let audioURL = URL(fileURLWithPath: options.audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw VoiceToolError.missingFile(audioURL.path)
        }

        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                model: options.model,
                verbose: options.verbose
            )
        )
        let decodeOptions = DecodingOptions(
            verbose: options.verbose,
            language: options.language,
            withoutTimestamps: true
        )
        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: decodeOptions
        )
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw VoiceToolError.emptyTranscript
        }

        switch options.format {
        case .json:
            try writeJSON(
                TranscriptionResponse(
                    text: text,
                    language: options.language,
                    segmentCount: results.count
                )
            )
        case .text:
            print(text)
        }
    }

    private static func synthesize(_ options: SynthesizeOptions) async throws {
        let outputURL = URL(fileURLWithPath: options.outputPath)
        let outputFolder = outputURL.deletingLastPathComponent()
        let outputFilename = outputURL.lastPathComponent.nilIfBlank ?? "speech.\(options.audioFormat.rawValue)"

        let tts = try await TTSKit(
            TTSKitConfig(model: options.model.variant)
        )
        var generationOptions = GenerationOptions()
        generationOptions.instruction = options.instruction

        let result = try await tts.generate(
            text: options.text,
            voice: options.speaker,
            language: options.language,
            options: generationOptions
        )
        let writtenURL = try await AudioOutput.saveAudio(
            result.audio,
            toFolder: outputFolder,
            filename: outputFilename,
            sampleRate: result.sampleRate,
            format: options.audioFormat.ttsFormat
        )

        try writeJSON(
            SynthesisResponse(
                audioPath: writtenURL.path,
                format: writtenURL.pathExtension,
                sampleRate: result.sampleRate,
                duration: result.audioDuration
            )
        )
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static let usage = """
    Usage:
      mlx-voice-transcriber transcribe --audio <path> [--model <model>] [--language <code>] [--format json|text]
      mlx-voice-transcriber synthesize --text <text> --output <path> [--model 0.6b|1.7b] [--language <language>] [--speaker <speaker>] [--format m4a|wav]

    Examples:
      mlx-voice-transcriber transcribe --audio prompt.m4a --model large-v3-v20240930_626MB --language it
      mlx-voice-transcriber synthesize --text "Ciao" --output reply.m4a --language italian --speaker ryan
    """
}

private enum VoiceCommand {
    case transcribe(TranscribeOptions)
    case synthesize(SynthesizeOptions)
    case help

    init(arguments: [String]) throws {
        guard let name = arguments.first else {
            self = .help
            return
        }

        let remaining = Array(arguments.dropFirst())
        switch name {
        case "transcribe":
            self = .transcribe(try TranscribeOptions(arguments: remaining))
        case "synthesize":
            self = .synthesize(try SynthesizeOptions(arguments: remaining))
        case "-h", "--help", "help":
            self = .help
        default:
            throw VoiceToolError.unknownCommand(name)
        }
    }
}

private struct TranscribeOptions {
    var audioPath: String
    var model: String
    var language: String?
    var format: OutputFormat
    var verbose: Bool

    init(arguments: [String]) throws {
        var parser = ArgumentParser(arguments)
        audioPath = try parser.requiredValue(for: "--audio")
        model = parser.value(for: "--model") ?? "large-v3-v20240930_626MB"
        language = parser.value(for: "--language")
        format = try OutputFormat(rawValue: parser.value(for: "--format") ?? "json")
            .orThrow(VoiceToolError.invalidValue("--format"))
        verbose = parser.flag("--verbose")
        try parser.rejectUnused()
    }
}

private struct SynthesizeOptions {
    var text: String
    var outputPath: String
    var model: SynthesisModel
    var language: String?
    var speaker: String?
    var instruction: String?
    var audioFormat: AudioFormat

    init(arguments: [String]) throws {
        var parser = ArgumentParser(arguments)
        if let inlineText = parser.value(for: "--text") {
            text = inlineText
        } else if let textFile = parser.value(for: "--text-file") {
            text = try String(contentsOfFile: textFile, encoding: .utf8)
        } else {
            throw VoiceToolError.missingArgument("--text")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw VoiceToolError.emptyText
        }

        outputPath = try parser.requiredValue(for: "--output")
        model = try SynthesisModel(rawValue: parser.value(for: "--model") ?? "0.6b")
            .orThrow(VoiceToolError.invalidValue("--model"))
        language = Self.normalizedSynthesisLanguage(parser.value(for: "--language"))
        speaker = parser.value(for: "--speaker")
        instruction = parser.value(for: "--instruction")
        audioFormat = try AudioFormat(rawValue: parser.value(for: "--format") ?? Self.outputFormat(from: outputPath))
            .orThrow(VoiceToolError.invalidValue("--format"))
        try parser.rejectUnused()
    }

    private static func outputFormat(from path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.nilIfBlank ?? "m4a"
    }

    private static func normalizedSynthesisLanguage(_ value: String?) -> String? {
        guard let normalized = value?.nilIfBlank?.lowercased() else {
            return nil
        }
        switch normalized {
        case "en":
            return "english"
        case "zh", "cn":
            return "chinese"
        case "ja", "jp":
            return "japanese"
        case "ko":
            return "korean"
        case "de":
            return "german"
        case "fr":
            return "french"
        case "ru":
            return "russian"
        case "pt":
            return "portuguese"
        case "es":
            return "spanish"
        case "it":
            return "italian"
        default:
            return normalized
        }
    }
}

private enum OutputFormat: String {
    case json
    case text
}

private enum AudioFormat: String {
    case m4a
    case wav

    var ttsFormat: AudioOutput.AudioFileFormat {
        switch self {
        case .m4a:
            return .m4a
        case .wav:
            return .wav
        }
    }
}

private enum SynthesisModel: String {
    case small = "0.6b"
    case large = "1.7b"

    var variant: TTSModelVariant {
        switch self {
        case .small:
            return .qwen3TTS_0_6b
        case .large:
            return .qwen3TTS_1_7b
        }
    }
}

private struct TranscriptionResponse: Encodable {
    let text: String
    let language: String?
    let segmentCount: Int
}

private struct SynthesisResponse: Encodable {
    let audioPath: String
    let format: String
    let sampleRate: Int
    let duration: Double
}

private struct ArgumentParser {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []
    private var unused: [String] = []

    init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                if index + 1 < arguments.count,
                   !arguments[index + 1].hasPrefix("--") {
                    values[argument] = arguments[index + 1]
                    index += 2
                } else {
                    flags.insert(argument)
                    index += 1
                }
            } else {
                unused.append(argument)
                index += 1
            }
        }
    }

    mutating func value(for name: String) -> String? {
        values.removeValue(forKey: name)
    }

    mutating func flag(_ name: String) -> Bool {
        flags.remove(name) != nil
    }

    mutating func requiredValue(for name: String) throws -> String {
        guard let value = self.value(for: name)?.nilIfBlank else {
            throw VoiceToolError.missingArgument(name)
        }
        return value
    }

    func rejectUnused() throws {
        if let name = values.keys.sorted().first ?? flags.sorted().first ?? unused.first {
            throw VoiceToolError.unexpectedArgument(name)
        }
    }
}

private enum VoiceToolError: LocalizedError {
    case unknownCommand(String)
    case missingArgument(String)
    case unexpectedArgument(String)
    case invalidValue(String)
    case missingFile(String)
    case emptyTranscript
    case emptyText

    var errorDescription: String? {
        switch self {
        case let .unknownCommand(name):
            return "unknown command '\(name)'"
        case let .missingArgument(name):
            return "missing required argument \(name)"
        case let .unexpectedArgument(name):
            return "unexpected argument \(name)"
        case let .invalidValue(name):
            return "invalid value for \(name)"
        case let .missingFile(path):
            return "file does not exist: \(path)"
        case .emptyTranscript:
            return "transcription returned no text"
        case .emptyText:
            return "text is empty"
        }
    }
}

private extension Optional {
    func orThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
