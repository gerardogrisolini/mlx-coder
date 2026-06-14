//
//  MLXServerSetupRunner.swift
//  mlx-coder
//

import Foundation
import MLXServerCore

public enum MLXServerSetupRunner {
    static let interactiveLineReader = MLXServerSetupInteractiveLineReader()

    public static func run(arguments: [String]) throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerSetupError.nonInteractiveTerminal
        }

        let settingsURL = MLXServerSettingsStore.settingsURL()
        let hadSettingsFile = FileManager.default.fileExists(atPath: settingsURL.path)
        FileHandle.standardError.writeString(
            """
            mlx-coder MLX setup
            Configuring settings.json at:
            \(settingsURL.path)

            """
        )

        var originalSettings: MLXServerSettings?
        var settings = MLXServerSettings()
        if hadSettingsFile {
            do {
                settings = try MLXServerSettingsStore.loadRequired(from: settingsURL)
                originalSettings = settings
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "settings.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
                FileHandle.standardError.writeString(
                    "Invalid settings will be replaced with defaults unless you edit a section.\n\n"
                )
            }
        } else {
            FileHandle.standardError.writeString(
                "No settings.json found. Defaults will be used unless you edit a section.\n\n"
            )
        }

        var didChangeSettings = false
        while true {
            let section = try promptSetupSection(
                currentSettings: settings,
                settingsExists: originalSettings != nil
            )
            guard section != .finish else {
                break
            }

            let previousSettings = settings
            settings = try configureSetupSection(section, currentSettings: settings)
            if settings != previousSettings {
                didChangeSettings = true
            }

            guard try promptYesNo("Modify another setup section?", defaultValue: false) else {
                break
            }
        }

        let finalSettings = try settings.validated()
        let shouldWriteSettings = didChangeSettings
            || originalSettings == nil
            || finalSettings != originalSettings
        if shouldWriteSettings {
            try MLXServerSettingsStore.save(finalSettings, to: settingsURL)
            FileHandle.standardError.writeString(
                hadSettingsFile ? "Updated: settings.json\n" : "Created: settings.json\n"
            )
        } else {
            FileHandle.standardError.writeString("Preserved: settings.json\n")
        }
        printRuntimeSetupCompleted()
    }

    static func printRuntimeSetupCompleted() {
        FileHandle.standardError.writeString("\nRuntime setup completed.\n")
    }

}
