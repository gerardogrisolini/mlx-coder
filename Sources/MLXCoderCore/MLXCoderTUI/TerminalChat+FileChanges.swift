//
//  TerminalChat+FileChanges.swift
//  mlx-coder
//
//  TUI rendering and undo commands for tracked file changes.
//

import Foundation

extension TerminalChat {
    public func publishFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator
    ) async -> TurnFileChangeSummary? {
        guard let summary = await collectFileChangeSummaryIfNeeded(from: coordinator) else {
            return nil
        }

        writeFileChangeSummary(summary, includeDiff: false)
        return summary
    }

    public func collectFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator
    ) async -> TurnFileChangeSummary? {
        guard let summary = await coordinator.publishSummaryIfNeeded() else {
            return nil
        }

        lastFileChangeSummary = summary
        return summary
    }

    public func handleChangesCommand(_ command: String) {
        let arguments = String(command.dropFirst("/changes".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let includeDiff = arguments == "diff" || arguments == "--diff"

        guard let summary = lastFileChangeSummary else {
            writeSystemMessage("No tracked file changes.\n")
            return
        }

        writeFileChangeSummary(summary, includeDiff: includeDiff)
    }

    public func handleUndoFileChangesCommand() async {
        do {
            try await TurnFileChangeUndoService.undoLatest(
                summary: lastFileChangeSummary,
                baseDirectoryURL: configuration.workingDirectory
            )
            lastFileChangeSummary = nil
            writeSystemMessage("File changes reverted.\n")
        } catch let error as TurnFileChangeUndoError {
            writeSystemMessage("\(error.localizedDescription)\n")
        } catch {
            writeFailureMessage(
                "mlx-coder: unable to undo file changes: \(error.localizedDescription)\n"
            )
        }
    }

    public func writeFileChangeSummary(
        _ summary: TurnFileChangeSummary,
        includeDiff: Bool
    ) {
        writeFileChangeSummaryMessage(Self.renderFileChangeSummary(summary))

        guard includeDiff else {
            return
        }

        writeFileChangeDiffs(summary)
    }

    public static func renderFileChangeSummary(
        _ summary: TurnFileChangeSummary
    ) -> String {
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        let undoText = summary.canUndo
            ? "Use /undo to revert, /changes diff to show patches."
            : "Undo is not available for this summary."

        var lines = ["", "Changed files: \(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"]
        lines.append(contentsOf: summary.entries.map(Self.renderFileChangeEntry))
        lines.append(undoText)
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderFileChangeEntry(
        _ entry: TurnFileChangeSummary.Entry
    ) -> String {
        if entry.isBinary {
            return "  \(entry.status.rawValue) \(entry.path) (binary)"
        }

        return "  \(entry.status.rawValue) \(entry.path)  +\(entry.additions) -\(entry.deletions)"
    }

    public func writeFileChangeDiffs(_ summary: TurnFileChangeSummary) {
        let patches = summary.entries.compactMap { entry -> String? in
            guard !entry.isBinary,
                  let patch = entry.patch?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !patch.isEmpty else {
                return nil
            }
            return patch
        }

        guard !patches.isEmpty else {
            writeSystemMessage("No text patches available.\n")
            return
        }

        let maxLines = 500
        let patchLines = patches
            .joined(separator: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleLines = patchLines.prefix(maxLines)
        writeChatError(
            "\n" + visibleLines.joined(separator: "\n") + "\n"
        )

        if patchLines.count > maxLines {
            writeSystemMessage(
                "... diff truncated at \(maxLines) lines.\n"
            )
        }
    }
}
