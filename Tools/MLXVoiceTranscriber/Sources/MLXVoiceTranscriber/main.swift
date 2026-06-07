//
//  main.swift
//  mlx-voice-transcriber
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(WhisperKit)
import WhisperKit
#endif

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
        #if canImport(WhisperKit)
        let audioURL = URL(fileURLWithPath: options.audioPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw VoiceToolError.missingFile(audioURL.path)
        }

        writeStatus("Loading speech model \(options.model)...")
        let whisperKit = try await WhisperKit(
            WhisperKitConfig(
                model: options.model,
                verbose: options.verbose
            )
        )
        writeStatus("Transcribing audio...")
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

        writeStatus("Transcript ready.")
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
        #else
        _ = options
        throw VoiceToolError.unsupportedTranscription
        #endif
    }

    private static func synthesize(_ options: SynthesizeOptions) async throws {
        #if os(macOS)
        let outputURL = URL(fileURLWithPath: options.outputPath)
        let outputFolder = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let systemVoice = options.voice?.nilIfBlank
            ?? Self.defaultSystemVoice(for: options.language)
        let intermediateURL = outputFolder
            .appendingPathComponent("mlx-voice-\(UUID().uuidString)")
            .appendingPathExtension("aiff")
        defer {
            try? FileManager.default.removeItem(at: intermediateURL)
        }

        writeStatus("Generating speech with \(systemVoice)...")
        try runProcess(
            executablePath: "/usr/bin/say",
            arguments: ["-v", systemVoice, "-o", intermediateURL.path, options.text]
        )
        switch options.audioFormat {
        case .m4a:
            try runProcess(
                executablePath: "/usr/bin/afconvert",
                arguments: ["-f", "m4af", "-d", "aac", intermediateURL.path, outputURL.path]
            )
        case .wav:
            try runProcess(
                executablePath: "/usr/bin/afconvert",
                arguments: ["-f", "WAVE", "-d", "LEI16", intermediateURL.path, outputURL.path]
            )
        }

        writeStatus("Speech ready.")
        try writeJSON(
            SynthesisResponse(
                audioPath: outputURL.path,
                format: outputURL.pathExtension,
                voice: systemVoice
            )
        )
        #else
        _ = options
        throw VoiceToolError.unsupportedAudioSynthesis
        #endif
    }

    private static func writeJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeStatus(_ message: String) {
        FileHandle.standardError.write(Data("[mlx-voice] \(message)\n".utf8))
    }

    private static func defaultSystemVoice(for language: String?) -> String {
        switch language?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "it", "italian", "italiano":
            return "Alice"
        case "en", "english":
            return "Samantha"
        case "es", "spanish":
            return "Paulina"
        case "fr", "french":
            return "Thomas"
        case "de", "german", "deutsch":
            return "Anna"
        case "pt", "portuguese":
            return "Joana"
        case "ja", "japanese":
            return "Kyoko"
        case "ko", "korean":
            return "Yuna"
        case "zh", "chinese":
            return "Tingting"
        case "ru", "russian":
            return "Milena"
        default:
            return "Samantha"
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let standardError = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = standardError.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)
            throw VoiceToolError.processFailed(
                URL(fileURLWithPath: executablePath).lastPathComponent,
                process.terminationStatus,
                detail
            )
        }
    }

    private static let usage = """
    Usage:
      mlx-voice-transcriber transcribe --audio <path> [--model <model>] [--language <code>] [--format json|text]
      mlx-voice-transcriber synthesize --text <text> --output <path> [--language <language>] [--voice <system-voice>] [--format m4a|wav]

    Examples:
      mlx-voice-transcriber transcribe --audio prompt.m4a --model tiny --language it
      mlx-voice-transcriber synthesize --text "Ciao" --output reply.m4a --language it --voice Alice
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
        model = parser.value(for: "--model") ?? "tiny"
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
    var language: String?
    var voice: String?
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
        language = parser.value(for: "--language")?.nilIfBlank?.lowercased()
        voice = parser.value(for: "--voice")?.nilIfBlank
        audioFormat = try AudioFormat(rawValue: parser.value(for: "--format") ?? Self.outputFormat(from: outputPath))
            .orThrow(VoiceToolError.invalidValue("--format"))
        try parser.rejectUnused()
    }

    private static func outputFormat(from path: String) -> String {
        URL(fileURLWithPath: path).pathExtension.nilIfBlank ?? "m4a"
    }
}

private enum OutputFormat: String {
    case json
    case text
}

private enum AudioFormat: String {
    case m4a
    case wav
}

private struct TranscriptionResponse: Encodable {
    let text: String
    let language: String?
    let segmentCount: Int
}

private struct SynthesisResponse: Encodable {
    let audioPath: String
    let format: String
    let voice: String
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
    case processFailed(String, Int32, String?)
    case unsupportedTranscription
    case unsupportedAudioSynthesis

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
        case let .processFailed(name, exitCode, detail):
            let cleanedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cleanedDetail, !cleanedDetail.isEmpty {
                return "\(name) failed with exit code \(exitCode): \(cleanedDetail)"
            }
            return "\(name) failed with exit code \(exitCode)"
        case .unsupportedTranscription:
            return "speech transcription is not supported in this build"
        case .unsupportedAudioSynthesis:
            return "audio generation is available only on macOS"
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
