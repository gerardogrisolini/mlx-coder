//
//  MLXServerModelSetupRunner+RemoteModels.swift
//  mlx-coder
//

import Foundation
import HuggingFace
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func configureRemoteModel() async throws -> ConfiguredModelRecord? {
        let client = MLXServerHuggingFaceCacheAccessStore.hubClient()
        guard let selectedModel = try await selectHuggingFaceModel(client: client) else {
            return nil
        }
        let repositoryID = selectedModel.id.rawValue
        let revision = selectedModel.sha ?? "main"

        FileHandle.standardError.writeString("\nDownloading \(repositoryID) [\(revision)]...\n")
        let snapshotURL = try await client.downloadSnapshot(
            of: selectedModel.id,
            revision: revision,
            progressHandler: { progress in
                Self.printDownloadProgress(progress)
            }
        )
        FileHandle.standardError.writeString("\nDownload completed: \(snapshotURL.path)\n")

        return try configureModelRecord(
            repositoryID: repositoryID,
            revision: revision,
            snapshotURL: snapshotURL,
            defaultRuntimeKind: inferredRuntimeKind(
                fromSnapshot: snapshotURL,
                fallback: inferredRuntimeKind(from: selectedModel)
            )
        )
    }

    static func selectHuggingFaceModel(client: HubClient) async throws -> Model? {
        searchLoop: while true {
            let query = try promptString(
                "Hugging Face MLX search",
                defaultValue: nil,
                allowEmpty: true
            ).trimmedNonEmpty

            let models: [Model]
            do {
                models = try await searchHuggingFaceModels(
                    client: client,
                    query: query
                )
            } catch {
                FileHandle.standardError.writeString(
                    "Hugging Face search failed: \(describeHuggingFaceError(error))\n"
                )
                FileHandle.standardError.writeString("Try a different search.\n")
                continue
            }

            guard !models.isEmpty else {
                FileHandle.standardError.writeString("No MLX model found.\n")
                continue
            }

            FileHandle.standardError.writeString("\n")
            for (index, model) in models.enumerated() {
                let downloads = model.downloads.map { "\($0) download" } ?? "download n/a"
                let likes = model.likes.map { "\($0) like" } ?? "like n/a"
                FileHandle.standardError.writeString(
                    "\(index + 1). \(model.id.rawValue) - \(downloads), \(likes)\n"
                )
            }

            while true {
                let answer = try promptString(
                    "Select model (number, s to search again, c to continue without download)",
                    defaultValue: "1",
                    allowEmpty: false
                )
                guard let selection = MLXServerModelSetupInputParser.parseSearchSelection(
                    answer,
                    defaultSelection: 1,
                    allowedRange: 1...models.count
                ) else {
                    FileHandle.standardError.writeString("Invalid model selection.\n")
                    continue
                }

                switch selection {
                case let .model(selection):
                    return models[selection - 1]
                case .searchAgain:
                    continue searchLoop
                case .continueWithoutDownload:
                    return nil
                }
            }
        }
    }

    static func searchHuggingFaceModels(
        client: HubClient,
        query: String?
    ) async throws -> [Model] {
        let response = try await client.listModels(
            search: query,
            filter: "mlx",
            sort: "downloads",
            direction: .descending,
            limit: 10,
            full: true
        )
        return response.items.filter(isUsableMLXModel)
    }

    static func describeHuggingFaceError(_ error: Error) -> String {
        if let error = error as? HTTPClientError {
            return error.description
        }
        return error.localizedDescription
    }

    static func printDownloadProgress(_ progress: Progress) {
        let fraction = progress.fractionCompleted.isFinite
            ? min(max(progress.fractionCompleted, 0), 1)
            : 0
        let percent = Int((fraction * 100).rounded(.down))
        let completed = max(progress.completedUnitCount, 0)
        let total = max(progress.totalUnitCount, 0)
        let sizeDetail = total > 1
            ? " \(formatBytes(completed)) / \(formatBytes(total))"
            : ""
        FileHandle.standardError.writeString("\rDownload: \(percent)%\(sizeDetail)")
    }

    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: bytes,
            countStyle: .file
        )
    }

    static func isUsableMLXModel(_ model: Model) -> Bool {
        let tags = model.tags ?? []
        let hasMLXTag = tags.contains { $0.localizedCaseInsensitiveContains("mlx") }
        let hasModelFiles = model.siblings?.contains { sibling in
            let filename = sibling.relativeFilename.lowercased()
            return filename == "config.json"
                || filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
        } ?? true
        return hasMLXTag && hasModelFiles && model.isDisabled != true
    }

    static func inferredRuntimeKind(from model: Model) -> MLXServerModelRuntimeKind {
        let searchable = ((model.tags ?? []) + [model.pipelineTag, model.library].compactMap { $0 })
            .joined(separator: " ")
            .lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    static func inferredRuntimeKind(
        fromSnapshot snapshotURL: URL,
        fallback: MLXServerModelRuntimeKind
    ) -> MLXServerModelRuntimeKind {
        if let probe = decodeRuntimeKindProbe(from: snapshotURL),
           let preferredRuntimeKind = probe.preferredTextRuntimeKind {
            return preferredRuntimeKind
        }

        if hasVisionProcessorFiles(in: snapshotURL) {
            return .vlm
        }

        return fallback
    }

    static func inferredRuntimeKind(fromRepositoryID repositoryID: String) -> MLXServerModelRuntimeKind {
        let searchable = repositoryID.lowercased()
        if searchable.contains("vision")
            || searchable.contains("image")
            || searchable.contains("vlm") {
            return .vlm
        }
        return .llm
    }

    static func decodeRuntimeKindProbe(from snapshotURL: URL) -> ModelRuntimeKindProbe? {
        let configURL = snapshotURL.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else {
            return nil
        }
        return try? JSONDecoder().decode(ModelRuntimeKindProbe.self, from: data)
    }

}
