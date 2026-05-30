//
//  TerminalChat+FileChanges.swift
//  mlx-coder
//
//  TUI rendering and undo commands for tracked file changes.
//

import Foundation

extension TerminalChat {
    public func publishFileChangeSummaryIfNeeded(
        from tracker: TurnFileChangeTracker
    ) async {
        guard let summary = await tracker.makeSummary() else {
            return
        }

        lastFileChangeSummary = summary
        writeFileChangeSummary(summary, includeDiff: false)
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
        guard let summary = lastFileChangeSummary else {
            writeSystemMessage("No tracked file changes to undo.\n")
            return
        }

        guard summary.canUndo else {
            writeSystemMessage(
                "Undo is not available for the latest file change summary.\n"
            )
            return
        }

        do {
            try await TurnFileChangeUndoService.undo(
                summary: summary,
                baseDirectoryURL: configuration.workingDirectory
            )
            lastFileChangeSummary = nil
            writeSystemMessage("File changes reverted.\n")
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
        let title = summary.fileCount == 1
            ? "1 modified file"
            : "\(summary.fileCount) modified files"
        let undoText = summary.canUndo
            ? "Use /undo to revert, /changes diff to show patches."
            : "Undo is not available for this summary."

        var lines = [
            "",
            "\(title)  +\(summary.totalAdditions) -\(summary.totalDeletions)"
        ]
        lines.append(contentsOf: summary.entries.map(Self.renderFileChangeEntry))
        lines.append(undoText)

        writeSystemMessage(lines.joined(separator: "\n") + "\n")

        guard includeDiff else {
            return
        }

        writeFileChangeDiffs(summary)
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
