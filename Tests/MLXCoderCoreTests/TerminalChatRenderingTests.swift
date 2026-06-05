@testable import MLXCoderCore
import Testing

@Suite
struct TerminalChatRenderingTests {
    @Test
    func exposesSharedAgentVersion() {
        #expect(agentVersion == "0.1.5")
    }

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

        #expect(lines.contains("⚙️  Edit:"))
        #expect(lines.contains { $0.contains("Sources/App.swift") })
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
