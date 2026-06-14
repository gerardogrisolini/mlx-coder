//
//  MLXServerModelSetupRunner.swift
//  mlx-coder
//

import Foundation
import HuggingFace
import MLXServerCore

public enum MLXServerModelSetupRunner {
    static let recommendedContextWindow = 65_536
    static let interactiveLineReader = MLXServerSetupInteractiveLineReader()

    @MainActor
    public static func run(arguments: [String], configureRetentionPolicy: Bool = true) async throws {
        _ = arguments
        guard supportsInteractiveInput() else {
            throw MLXServerModelSetupError.nonInteractiveTerminal
        }

        let modelsURL = MLXServerModelsManifestStore.modelsURL()
        FileHandle.standardError.writeString(
            """
            mlx-coder MLX models setup
            Configuring models.json at:
            \(modelsURL.path)

            """
        )

        if configureRetentionPolicy {
            try configureModelRetentionPolicy()
        }
        try await MLXServerHuggingFaceCachePermissionRequester.ensureAccessIfNeeded()

        var manifest = MLXServerModelsManifest()
        let modelsFileExists = FileManager.default.fileExists(atPath: modelsURL.path)
        if modelsFileExists {
            do {
                manifest = try MLXServerModelsManifestStore.loadRequired(from: modelsURL)
                refreshExistingModelRuntimeKinds(in: &manifest)
                printExistingModels(manifest)
                try removeConfiguredModelsIfRequested(in: &manifest)
                try reconfigureExistingModelsIfRequested(in: &manifest)
            } catch {
                let shouldOverwrite = try promptYesNo(
                    "models.json exists but is invalid. Rewrite it?",
                    defaultValue: true
                )
                guard shouldOverwrite else {
                    throw error
                }
            }
        }

        try importCachedModelsIfRequested(into: &manifest)

        let shouldConfigureRemoteModel = try promptYesNo(
            "Search and download more models from Hugging Face?",
            defaultValue: manifest.models.isEmpty
        )
        if shouldConfigureRemoteModel {
            while true {
                guard let configuredModel = try await configureRemoteModel() else {
                    break
                }
                upsert(record: configuredModel.record, in: &manifest)
                try updateDefaultModel(
                    afterAdding: configuredModel.record,
                    in: &manifest
                )
                guard try promptYesNo("Add another model?", defaultValue: false) else {
                    break
                }
            }
        }

        try selectDefaultModelIfRequested(in: &manifest)
        try MLXServerModelsManifestStore.save(manifest, to: modelsURL)
        FileHandle.standardError.writeString("Updated: models.json\n")
        FileHandle.standardError.writeString("\nModels setup completed.\n\n")
    }

}
