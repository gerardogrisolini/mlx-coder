import Foundation
@testable import MLXCoderCore
import Testing

@Suite(.serialized)
struct TurnFileChangeCoordinatorTests {
    @Test
    func undoLatestThrowsWhenNoChangesAreTracked() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)

        do {
            _ = try await coordinator.undoLatestChanges()
            Issue.record("undoLatestChanges should throw without a summary.")
        } catch let error as TurnFileChangeUndoError {
            #expect(error == .noTrackedFileChanges)
        }
    }

    @Test
    func undoLatestThrowsWhenSummaryCannotBeUndone() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 1,
                    deletions: 0,
                    status: .modified,
                    isBinary: false,
                    existedBefore: nil,
                    beforeDataBase64: nil,
                    patch: nil
                )
            ]
        )

        do {
            _ = try await TurnFileChangeUndoService.undoLatest(
                summary: summary,
                baseDirectoryURL: directory
            )
            Issue.record("undoLatest should throw for non-undoable summaries.")
        } catch let error as TurnFileChangeUndoError {
            #expect(error == .unavailable)
        }
    }

    @Test
    func undoLatestRestoresFilesAndClearsCoordinatorSummary() async throws {
        let directory = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appendingPathComponent("Sources/App.swift")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let before = Data("let value = 1\n".utf8)
        let after = Data("let value = 2\n".utf8)
        try after.write(to: fileURL)
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 1,
                    deletions: 1,
                    status: .modified,
                    isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: before.base64EncodedString(),
                    patch: nil
                )
            ]
        )
        let coordinator = TurnFileChangeCoordinator(baseDirectoryURL: directory)
        await coordinator.replaceLatestSummary(summary)

        let undoneSummary = try await coordinator.undoLatestChanges()

        #expect(undoneSummary == summary)
        #expect(try Data(contentsOf: fileURL) == before)
        #expect(await coordinator.latestFileChangeSummary() == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "turn-file-change-coordinator-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
