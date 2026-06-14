//
//  MLXServerModelSetupRunner+Prompting.swift
//  mlx-coder
//

import Foundation
import HuggingFace
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func promptString(
        _ prompt: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt)\(suffix): ") else {
                throw MLXServerModelSetupError.inputClosed
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, let defaultValue {
                return defaultValue
            }
            if trimmed.isEmpty, allowEmpty {
                return ""
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

    static func promptFloat(
        _ prompt: String,
        defaultValue: Float,
        allowedRange: ClosedRange<Float>
    ) throws -> Float {
        while true {
            let value = try promptString(
                prompt,
                defaultValue: formatFloat(defaultValue),
                allowEmpty: false
            )
            guard let parsed = Float(value.replacingOccurrences(of: ",", with: ".")),
                  allowedRange.contains(parsed) else {
                FileHandle.standardError.writeString("Invalid value.\n")
                continue
            }
            return parsed
        }
    }

    static func formatFloat(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    static func promptYesNo(
        _ prompt: String,
        defaultValue: Bool
    ) throws -> Bool {
        let defaultLabel = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = interactiveLineReader.readLine(prompt: "\(prompt) [\(defaultLabel)]: ") else {
                throw MLXServerModelSetupError.inputClosed
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
