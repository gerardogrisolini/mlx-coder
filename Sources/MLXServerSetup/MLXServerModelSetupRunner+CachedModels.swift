//
//  MLXServerModelSetupRunner+CachedModels.swift
//  mlx-coder
//

import Foundation
import HuggingFace
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func importCachedModelsIfRequested(into manifest: inout MLXServerModelsManifest) throws {
        let candidates = MLXServerCachedModelScanner.candidates(
            cache: MLXServerHuggingFaceCacheAccessStore.cache
        )
        guard !candidates.isEmpty else {
            return
        }
        let importableCandidates = candidates.filter { candidate in
            !manifest.models.contains { model in
                model.repositoryID == candidate.repositoryID
                    && model.revision == candidate.revision
            }
        }
        guard !importableCandidates.isEmpty else {
            FileHandle.standardError.writeString(
                "Downloaded models are already configured in models.json.\n\n"
            )
            return
        }

        FileHandle.standardError.writeString(
            """
            Found downloaded models in the Hugging Face cache that are not configured yet:

            """
        )
        for (index, candidate) in importableCandidates.enumerated() {
            FileHandle.standardError.writeString(
                "\(index + 1). \(candidate.repositoryID) [\(candidate.revision)]\n"
            )
        }
        FileHandle.standardError.writeString("\n")

        guard try promptYesNo(
            "Import them into models.json?",
            defaultValue: true
        ) else {
            try deleteRejectedCachedModelsIfRequested(importableCandidates)
            return
        }

        for candidate in importableCandidates {
            guard try promptYesNo(
                "Import \(candidate.repositoryID)?",
                defaultValue: true
            ) else {
                try deleteRejectedCachedModelIfRequested(candidate)
                continue
            }
            let configuredModel = try configureCachedModel(candidate)
            upsert(record: configuredModel.record, in: &manifest)
            try updateDefaultModel(
                afterAdding: configuredModel.record,
                in: &manifest
            )
        }
    }

    static func deleteRejectedCachedModelIfRequested(
        _ candidate: MLXServerCachedModelCandidate
    ) throws {
        guard try promptYesNo(
            "Delete \(candidate.repositoryID) [\(candidate.revision)] from the Hugging Face cache?",
            defaultValue: false
        ) else {
            return
        }

        try removeCachedRepository(repositoryID: candidate.repositoryID)
    }

    static func deleteRejectedCachedModelsIfRequested(
        _ candidates: [MLXServerCachedModelCandidate]
    ) throws {
        for candidate in candidates {
            try deleteRejectedCachedModelIfRequested(candidate)
        }
    }

    static func inferredRuntimeKind(from candidate: MLXServerCachedModelCandidate) -> MLXServerModelRuntimeKind {
        inferredRuntimeKind(
            fromSnapshot: candidate.snapshotURL,
            fallback: inferredRuntimeKind(fromRepositoryID: candidate.repositoryID)
        )
    }

    static func cachedCandidate(
        for model: MLXServerModelRecord,
        in candidates: [MLXServerCachedModelCandidate]
    ) -> MLXServerCachedModelCandidate? {
        candidates.first {
            $0.repositoryID == model.repositoryID && $0.revision == model.revision
        } ?? candidates.first {
            $0.repositoryID == model.repositoryID
        }
    }

    static func hasVisionProcessorFiles(in snapshotURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: snapshotURL.appendingPathComponent("preprocessor_config.json").path
        )
            || FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("image_processor_config.json").path
            )
            || FileManager.default.fileExists(
                atPath: snapshotURL.appendingPathComponent("processor_config.json").path
            )
    }
}
