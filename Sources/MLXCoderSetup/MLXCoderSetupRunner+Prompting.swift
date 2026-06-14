//
//  MLXCoderSetupRunner+Prompting.swift
//  mlx-coder
//

import Foundation
import MLXCoderCore

extension MLXCoderSetupRunner {
    static func promptString(
        _ label: String,
        defaultValue: String?,
        allowEmpty: Bool
    ) throws -> String {
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        guard let rawValue = interactiveLineReader.readLine(prompt: "\(label)\(suffix): ") else {
            throw MLXCoderSetupError.cancelled
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty, let defaultValue {
            return defaultValue
        }
        if value.isEmpty, !allowEmpty {
            throw MLXCoderSetupError.emptyRequiredValue(label)
        }
        return value
    }

    static func promptYesNo(
        _ label: String,
        defaultValue: Bool
    ) throws -> Bool {
        let suffix = defaultValue ? " [Y/n]" : " [y/N]"
        let value = try promptString(label + suffix, defaultValue: nil, allowEmpty: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.isEmpty {
            return defaultValue
        }
        switch value {
        case "y", "yes":
            return true
        case "n", "no":
            return false
        default:
            throw MLXCoderSetupError.invalidChoice(value)
        }
    }

    static func printResult(
        _ result: MLXCoderSupportFileResult,
        settingsWasWritten: Bool
    ) {
        if !result.createdFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Created: \(result.createdFilenames.joined(separator: ", "))\n"
            )
        }
        if !result.preservedFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Preserved: \(result.preservedFilenames.joined(separator: ", "))\n"
            )
        }
        if settingsWasWritten && !result.createdFilenames.contains(AgentSettingsManifestStore.settingsFilename) {
            AgentOutput.standardError.writeString("Updated: settings.json\n")
        }
    }
}
