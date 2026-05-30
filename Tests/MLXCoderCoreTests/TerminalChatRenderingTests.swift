@testable import MLXCoderCore
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
    func compactToolStatusIconStaysImmediatelyAfterText() {
        let rendered = TerminalChat.compactToolStatusLine(
            target: "/tmp/generated-feature/Sources/Feature/main.swift",
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(rendered.hasSuffix(" ✅"))
        #expect(!rendered.contains("  ✅"))
    }
}
