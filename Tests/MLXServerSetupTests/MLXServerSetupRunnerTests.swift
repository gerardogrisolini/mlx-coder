//
//  MLXServerSetupRunnerTests.swift
//  mlx-server
//

import Foundation
import HuggingFace
import Testing
@testable import MLXServerSetup

@Test
func setupDoubleParserAcceptsDotAndCommaDecimalSeparators() {
    #expect(MLXServerSetupInputParser.parseDouble("1.25") == 1.25)
    #expect(MLXServerSetupInputParser.parseDouble("1,25") == 1.25)
}

@Test
func setupDoubleParserRejectsAmbiguousDecimalSeparators() {
    #expect(MLXServerSetupInputParser.parseDouble("1,2,3") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("1.2.3") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("1,2.3") == nil)
}

@Test
func setupDoubleParserRejectsNonFiniteValues() {
    #expect(MLXServerSetupInputParser.parseDouble("nan") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("inf") == nil)
    #expect(MLXServerSetupInputParser.parseDouble("-inf") == nil)
}

@Test
func setupPathInputLengthValidatorAllowsConfiguredMaximum() {
    let maximum = MLXServerSetupInputParser.maximumPathLength

    #expect(MLXServerSetupInputParser.isValidLength(String(repeating: "a", count: maximum), maximumLength: maximum))
    #expect(!MLXServerSetupInputParser.isValidLength(String(repeating: "a", count: maximum + 1), maximumLength: maximum))
}

@Test
func huggingFaceCacheRemovalDeletesRepositoryMetadataAndLocks() throws {
    let fileManager = FileManager.default
    let cacheRoot = fileManager.temporaryDirectory
        .appendingPathComponent("mlx-server-cache-removal-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? fileManager.removeItem(at: cacheRoot)
    }

    let cache = HubCache(cacheDirectory: cacheRoot)
    let urls = try #require(
        MLXServerHuggingFaceCacheRemoval.removalURLs(
            repositoryID: "mlx-community/Test-Model",
            cache: cache
        )
    )
    #expect(urls.contains(cacheRoot.appendingPathComponent("models--mlx-community--Test-Model")))
    #expect(urls.contains(cacheRoot.appendingPathComponent(".metadata/models--mlx-community--Test-Model")))
    #expect(urls.contains(cacheRoot.appendingPathComponent(".locks/models--mlx-community--Test-Model")))
    #expect(urls.contains(cacheRoot.appendingPathComponent(".locks/.metadata/models--mlx-community--Test-Model")))

    for url in urls {
        if url.path.contains("/.locks/") {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: url)
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    let result = try MLXServerHuggingFaceCacheRemoval.remove(
        repositoryID: "mlx-community/Test-Model",
        cache: cache,
        fileManager: fileManager
    )

    #expect(result == .removed)
    for url in urls {
        #expect(!fileManager.fileExists(atPath: url.path))
    }
}

@Test
func huggingFaceCacheRemovalRejectsInvalidRepositoryID() throws {
    let cache = HubCache(
        cacheDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-server-cache-removal-invalid-\(UUID().uuidString)", isDirectory: true)
    )

    #expect(
        try MLXServerHuggingFaceCacheRemoval.remove(
            repositoryID: "invalid-repository-id",
            cache: cache
        ) == .invalidRepositoryID
    )
    #expect(
        MLXServerHuggingFaceCacheRemoval.removalURLs(
            repositoryID: "invalid-repository-id",
            cache: cache
        ) == nil
    )
}

@Test
func modelSearchSelectionParserSelectsModelByNumberOrDefault() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "2",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .model(2)
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .model(1)
    )
}

@Test
func modelSearchSelectionParserCanSearchAgain() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "s",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .searchAgain
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "search again",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .searchAgain
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "cerca ancora",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .searchAgain
    )
}

@Test
func modelSearchSelectionParserCanContinueWithoutDownload() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "c",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .continueWithoutDownload
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "continue without download",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .continueWithoutDownload
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "continua senza scaricare",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == .continueWithoutDownload
    )
}

@Test
func modelSearchSelectionParserRejectsInvalidValues() {
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "4",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == nil
    )
    #expect(
        MLXServerModelSetupInputParser.parseSearchSelection(
            "not-a-choice",
            defaultSelection: 1,
            allowedRange: 1...3
        ) == nil
    )
}
