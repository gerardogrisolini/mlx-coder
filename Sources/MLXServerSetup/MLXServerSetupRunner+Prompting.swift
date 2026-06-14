//
//  MLXServerSetupRunner+Prompting.swift
//  mlx-coder
//

import Foundation
import MLXServerCore

extension MLXServerSetupRunner {
    static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        maximumLength: Int? = nil,
        isSecure: Bool = false
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            let linePrompt = "\(prompt)\(suffix): "
            let line = isSecure
                ? interactiveLineReader.readSecureLine(prompt: linePrompt)
                : interactiveLineReader.readLine(prompt: linePrompt)
            guard let line else {
                throw MLXServerSetupError.inputClosed
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, let defaultValue {
                return defaultValue
            }
            if trimmed.isEmpty, allowEmpty {
                return ""
            }
            if !MLXServerSetupInputParser.isValidLength(trimmed, maximumLength: maximumLength) {
                FileHandle.standardError.writeString(
                    "Invalid value: maximum length is \(maximumLength ?? 0) characters.\n"
                )
                continue
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }
    }

    static func promptInt(
        _ prompt: String,
        defaultValue: Int,
        allowedRange: ClosedRange<Int>
    ) throws -> Int {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Int(value), allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    static func promptDouble(
        _ prompt: String,
        defaultValue: Double,
        allowedRange: ClosedRange<Double>
    ) throws -> Double {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: String(format: "%.0f", defaultValue),
                allowEmpty: false
            )
            guard let parsed = MLXServerSetupInputParser.parseDouble(value),
                  allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt) [\(defaultLabel)]: ") else {
                throw MLXServerSetupError.inputClosed
            }
            let normalized = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized.isEmpty {
                return defaultValue
            }
            if ["y", "yes"].contains(normalized) {
                return true
            }
            if ["n", "no"].contains(normalized) {
                return false
            }
        }
    }

    static func supportsInteractiveInput() -> Bool {
        MLXServerSetupInteractiveLineReader.supportsInteractiveInput()
    }
}
