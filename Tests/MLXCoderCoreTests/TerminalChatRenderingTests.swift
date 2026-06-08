@testable import MLXCoderCore
import Foundation
import Testing

@Suite
struct TerminalChatRenderingTests {
    @Test
    func removingLeadingLineBreaksPreservesContent() {

        #expect(TerminalChat.removingLeadingLineBreaks("\n\nCiao") == "Ciao")
        #expect(TerminalChat.removingLeadingLineBreaks("\r\nCiao") == "Ciao")
        #expect(TerminalChat.removingLeadingLineBreaks("Ciao") == "Ciao")
        #expect(TerminalChat.removingLeadingLineBreaks("\n\n") == "")
    }

    @Test
    func thoughtBoundarySeparatorLeavesOneBlankLine() {
        #expect(TerminalChat.thoughtBoundarySeparator(endsWithNewline: false) == "\n\n")
        #expect(TerminalChat.thoughtBoundarySeparator(endsWithNewline: true) == "\n")
    }

    @Test
    func chatLineInsetIsAppliedOnlyAtLineStarts() {
        var isAtLineStart = true
        #expect(
            TerminalChat.chatLineInsetApplied(
                to: "ciao\nmondo",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == " ciao\n mondo"
        )
        #expect(isAtLineStart == false)

        #expect(
            TerminalChat.chatLineInsetApplied(
                to: "!",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == "!"
        )
        #expect(isAtLineStart == false)

        #expect(
            TerminalChat.chatLineInsetApplied(
                to: "\nOK",
                prefix: " ",
                isAtLineStart: &isAtLineStart
            ) == "\n OK"
        )
    }

    @Test
    func systemMessageColoringWrapsNonBlankLines() {
        let rendered = TerminalChat.systemMessageColorApplied(
            to: "Tool details: full\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\u{1B}[38;5;179mTool details: full\u{1B}[0m\n"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func startupInlineTextWrapsWithoutEllipsis() {
        #expect(TerminalChat.wrapInline("Commands: /help, /models, /agents", width: 18) == [
            "Commands: /help,",
            "/models, /agents"
        ])
        #expect(!TerminalChat.fitInline("Commands: /help, /models, /agents", width: 18).contains("..."))
    }

    @Test
    func markdownFormatterStylesHeadingsAndInlineCode() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)

        let rendered = formatter.consume("## Titolo con `codice`\n")

        #expect(rendered.contains("\u{1B}[1;38;5;81mTitolo con"))
        #expect(rendered.contains("\u{1B}[38;5;222mcodice\u{1B}[0m"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func markdownFormatterStreamsLongPlainLinesWithoutParsing() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let plain = String(repeating: "a", count: 241)

        #expect(formatter.consume(plain) == plain)
        #expect(formatter.finish() == "")
    }

    @Test
    func markdownFormatterKeepsPotentialMarkdownBufferedUntilNewline() {
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: true)
        let partial = "## " + String(repeating: "a", count: 241)

        #expect(formatter.consume(partial) == "")
        #expect(formatter.consume("\n").contains("\u{1B}[1;38;5;81m"))
    }

    @Test
        func subAgentOverviewRendersPlainWrappedStatusWithoutBoxDrawing() {
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_1",
            name: "swift-scan",
            role: "swift-scan",
            isolationMode: .report,
            status: .closed,
            pending: false,
            latestOutput: "Trovati 3 file `.swift`: 1. `./Tests/MLXCoderCoreTests/AgentCoreSessionRunnerTests.swift` 2. `./Tests/MLXCoderCoreTests/MLXMemoryServiceTests.swift` 3. `./Tests/MLXCoderCoreTests/VeryLongFileNameThatShouldWrapInsideTheBox.swift`",
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )

        let rendered = TerminalChat.renderSubAgentOverview([snapshot])
        let visibleLines = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { ansiStripped(String($0)) }

        #expect(visibleLines.first == "Sub-Agents")
        #expect(!rendered.contains("┌"))
        #expect(!rendered.contains("│"))
        #expect(!rendered.contains("└"))
        #expect(visibleLines.allSatisfy { $0.count <= 122 })
    }

    @Test
    func failureMessageColoringWrapsNonBlankLines() {
        let rendered = TerminalChat.failureMessageColorApplied(
            to: "mlx-coder: HTTP 402\n\nRetry later.\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\u{1B}[38;5;203mmlx-coder: HTTP 402\u{1B}[0m\n\n"))
        #expect(rendered.contains("\u{1B}[38;5;203mRetry later.\u{1B}[0m\n"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func fileChangeSummaryRenderingUsesDistinctHeaderAndSpacing() {
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 12,
                    deletions: 2,
                    status: .modified,
                    isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: Data("before".utf8).base64EncodedString(),
                    patch: nil
                )
            ]
        )

        let rendered = TerminalChat.renderFileChangeSummary(summary)

        #expect(rendered.hasPrefix("\nChanged files: 1 modified file  +12 -2\n"))
        #expect(rendered.contains("  modified Sources/App.swift  +12 -2\n"))
        #expect(rendered.contains("Use /undo to revert, /changes diff to show patches.\n"))
    }

    @Test
    func fileChangeSummaryColoringHighlightsNonBlankLines() {
        let rendered = TerminalChat.fileChangeSummaryColorApplied(
            to: "\nChanged files: 1 modified file  +12 -2\n  modified Sources/App.swift  +12 -2\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\n\u{1B}[1;38;5;214mChanged files:"))
        #expect(rendered.contains("\u{1B}[1;38;5;214m  modified Sources/App.swift  +12 -2\u{1B}[0m\n"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func compactEditToolLinesIncludeFileTarget() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.editFile",
            argumentsObject: [
                "file_path": "Sources/App.swift",
                "oldString": "old",
                "newString": "new"
            ],
            argumentsJSON: #"{"file_path":"Sources/App.swift","oldString":"old","newString":"new"}"#
        )

        let lines = TerminalChat.compactToolLines(for: toolCall, statusIcon: "⏳")

        #expect(lines.contains("✏️  Edit:"))
        #expect(lines.contains { $0.contains("Sources/App.swift") })
    }

    @Test
    func toolIconsFollowConfiguredFamilies() {
        #expect(MLXCoderACPBridge.toolIcon(for: "local.exec") == "💻")
        #expect(MLXCoderACPBridge.toolIcon(for: "local.readFile") == "📄")
        #expect(MLXCoderACPBridge.toolIcon(for: "local.editFile") == "✏️")
        #expect(MLXCoderACPBridge.toolIcon(for: "local.delete") == "🗑️")
        #expect(MLXCoderACPBridge.toolIcon(for: "local.move") == "↔️")
        #expect(MLXCoderACPBridge.toolIcon(for: "memory.read") == "🧠")
        #expect(MLXCoderACPBridge.toolIcon(for: "agent.create") == "👥")
        #expect(MLXCoderACPBridge.toolIcon(for: "task.create") == "👥")
        #expect(MLXCoderACPBridge.toolIcon(for: "git.diff") == "🔀")
        #expect(MLXCoderACPBridge.toolIcon(for: "web.fetch") == "🌐")
        #expect(MLXCoderACPBridge.toolIcon(for: "search.grep") == "🔎")
        #expect(MLXCoderACPBridge.toolIcon(for: "xcode.BuildProject") == "🛠️")
        #expect(MLXCoderACPBridge.toolIcon(for: "figma.get") == "🎨")
        #expect(MLXCoderACPBridge.toolIcon(for: "jira.search") == "📋")
        #expect(MLXCoderACPBridge.toolIcon(for: "unknown.tool") == "🔨")
    }

    @Test
    func compactToolStatusIconStaysImmediatelyAfterText() {
        let rendered = TerminalChat.compactToolStatusLine(
            target: "/tmp/generated-feature/Sources/Feature/main.swift",
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(rendered.hasSuffix(" ✅"))
        #expect(!rendered.contains("  ✅"))
    }

    @Test
    func detailedReplaceCompletionShowsSnippetsAsCodeLines() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.editFile",
            argumentsObject: [
                "path": "Sources/App.swift",
                "oldString": "let oldValue = 1",
                "newString": "let newValue = 2"
            ],
            argumentsJSON: #"{"path":"Sources/App.swift","oldString":"let oldValue = 1","newString":"let newValue = 2"}"#
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: DirectAgentToolResult(output: "", summary: "ok")
        )

        #expect(lines.contains("old:"))
        #expect(lines.contains("  let oldValue = 1"))
        #expect(lines.contains("new:"))
        #expect(lines.contains("  let newValue = 2"))
    }

    @Test
    func detailedToolStartOmitsRawInputButKeepsDetails() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.readFile",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift"
            ],
            argumentsJSON: #"{"path":"/tmp/project/Sources/App.swift"}"#
        )

        let lines = TerminalChat.detailedToolCallStartedLines(for: toolCall)

        #expect(lines.contains("📄  Read /tmp/project/Sources/App.swift ⏳"))
        #expect(lines.contains("status: in_progress"))
        #expect(lines.contains("kind: read"))
        #expect(lines.contains("location: /tmp/project/Sources/App.swift"))
        #expect(!lines.contains("rawInput:"))
        #expect(!lines.contains { $0.contains("call_1") })
    }

    @Test
    func detailedReadCompletionOmitsRawOutputButKeepsSummaryDetail() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.readFile",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift"
            ],
            argumentsJSON: #"{"path":"/tmp/project/Sources/App.swift"}"#
        )
        let result = DirectAgentToolResult(
            output: "let value = 1\nlet second = 2",
            summary: "read 2 lines"
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("status: completed"))
        #expect(lines.contains("kind: read"))
        #expect(lines.contains("summary: read 2 lines"))
        #expect(!lines.contains("rawOutput.output:"))
        #expect(!lines.contains("let value = 1"))
    }

    @Test
    func detailedWriteCompletionShowsAppliedChangeSnippet() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.writeFile",
            argumentsObject: [
                "file_path": "/tmp/project/Sources/App.swift",
                "content": "struct App {\n    let value = 1\n}"
            ],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(
            output: "Wrote /tmp/project/Sources/App.swift",
            summary: "Wrote file"
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("change: write /tmp/project/Sources/App.swift"))
        #expect(lines.contains("content:"))
        #expect(lines.contains("  struct App {"))
        #expect(lines.contains("      let value = 1"))
        #expect(!lines.contains("rawOutput.summary: Wrote file"))
    }

    private func ansiStripped(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "\u{1B}",
               text.index(after: cursor) < text.endIndex,
               text[text.index(after: cursor)] == "[",
               let sequenceEnd = text[cursor...].firstIndex(of: "m") {
                cursor = text.index(after: sequenceEnd)
                continue
            }
            output.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return output
    }

    @Test
    func detailedReplaceCompletionShowsOldAndNewSnippets() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.replace",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift",
                "oldString": "let value = 1",
                "newString": "let value = 2",
                "replaceAll": true
            ],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.appliedChangeDetailLines(for: toolCall)

        #expect(lines.contains("change: replace /tmp/project/Sources/App.swift"))
        #expect(lines.contains("mode: replace all"))
        #expect(lines.contains("old:"))
        #expect(lines.contains("  let value = 1"))
        #expect(lines.contains("new:"))
        #expect(lines.contains("  let value = 2"))
    }
}
