//
//  MLXServerSetupRunner+Menu.swift
//  mlx-coder
//

import Foundation
import MLXServerCore

extension MLXServerSetupRunner {
    static func promptSetupSection(
        currentSettings settings: MLXServerSettings,
        settingsExists: Bool
    ) throws -> SetupSection {
        let options = setupSectionOptions(currentSettings: settings)
        let defaultSection: SetupSection = settingsExists ? .finish : .modelLoading
        let defaultIndex = options.firstIndex { $0.section == defaultSection } ?? 0

        FileHandle.standardError.writeString("Setup sections:\n")
        for (index, option) in options.enumerated() {
            let marker = index == defaultIndex ? " *" : ""
            let detail = option.detail.map { " - \($0)" } ?? ""
            FileHandle.standardError.writeString(
                "  \(index + 1). \(option.section.title)\(detail)\(marker)\n"
            )
        }

        let value = try promptString(
            "Section",
            defaultValue: String(defaultIndex + 1),
            allowEmpty: false
        )
        let normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = Int(normalizedValue),
           options.indices.contains(index - 1) {
            return options[index - 1].section
        }
        if let option = options.first(where: { $0.section.matches(normalizedValue) }) {
            return option.section
        }
        throw MLXServerSetupError.invalidChoice(value)
    }

    static func setupSectionOptions(
        currentSettings settings: MLXServerSettings
    ) -> [SetupSectionOption] {
        [
            SetupSectionOption(
                section: .modelLoading,
                detail: settings.loadOneModelAtATime ? "one model at a time" : "keep loaded models"
            ),
            SetupSectionOption(
                section: .kvCache,
                detail: kvCacheSetupDetail(settings.kvCache)
            ),
            SetupSectionOption(
                section: .diskKVCache,
                detail: diskKVCacheSetupDetail(settings.diskKVCache)
            ),
            SetupSectionOption(section: .finish, detail: nil)
        ]
    }

    static func kvCacheSetupDetail(_ settings: MLXServerKVCacheSettings) -> String {
        let settings = settings.validated()
        if let profile = KVCacheProfile.matching(settings) {
            return profile.title
        }
        switch settings.mode {
        case .standard:
            return "standard"
        case .quantized:
            return "quantized \(settings.quantizedBits)-bit, group \(settings.quantizedGroupSize), start \(settings.quantizedStart)"
        }
    }

    static func diskKVCacheSetupDetail(_ settings: MLXServerDiskKVCacheSettings) -> String {
        guard settings.enabled else {
            return "disabled"
        }
        let limit = settings.limitGB.map { String(format: "%.0f GB", $0) } ?? "no limit"
        if let directoryPath = settings.directoryPath?.nilIfEmpty {
            return "enabled, \(limit), \(directoryPath)"
        }
        return "enabled, \(limit), default directory"
    }

    static func configureSetupSection(
        _ section: SetupSection,
        currentSettings settings: MLXServerSettings
    ) throws -> MLXServerSettings {
        switch section {
        case .modelLoading:
            return try configureModelLoading(settings)
        case .kvCache:
            return try configureKVCache(settings)
        case .diskKVCache:
            return try configureDiskKVCache(settings)
        case .finish:
            return settings
        }
    }

}
