//
//  MLXServerModelSetupRunner+Retention.swift
//  mlx-coder
//

import Foundation
import HuggingFace
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func configureModelRetentionPolicy() throws {
        let settingsURL = MLXServerSettingsStore.settingsURL()
        let settingsExists = FileManager.default.fileExists(atPath: settingsURL.path)
        var settings = settingsExists
            ? try MLXServerSettingsStore.loadRequired(from: settingsURL)
            : MLXServerSettings()

        settings.loadOneModelAtATime = try promptYesNo(
            "Should mlx-coder --mlx load only one model at a time?",
            defaultValue: settings.loadOneModelAtATime
        )

        try MLXServerSettingsStore.save(settings, to: settingsURL)
        FileHandle.standardError.writeString("Updated: settings.json\n\n")
    }

    static func refreshExistingModelRuntimeKinds(in manifest: inout MLXServerModelsManifest) {
        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        for modelIndex in manifest.models.indices {
            let repositoryID = manifest.models[modelIndex].repositoryID
            let revision = manifest.models[modelIndex].revision
            guard let candidate = candidates.first(where: {
                $0.repositoryID == repositoryID && $0.revision == revision
            }) else {
                continue
            }
            manifest.models[modelIndex].runtimeKind = inferredRuntimeKind(from: candidate)
        }
    }

}
