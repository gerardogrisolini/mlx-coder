//
//  Generated split from TerminalChat.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

extension TerminalChat {
    public func printActiveToolsIfNeeded() async {
        guard !didPrintActiveTools else {
            return
        }
        didPrintActiveTools = true
        await printToolSelectionStatus()
    }

    public func printStartupSummary() async {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        let toolItems = await toolSelectionItems()
        didPrintActiveTools = true

        var lines = [
            "Version: \(Self.appVersionDescription)",
            Self.renderActiveTools(
                Array(allowedToolNames),
                items: toolItems,
                selectedKeys: selectedToolKeys
            )
                .trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        if let selectedAgent {
            lines.insert("Agent: \(selectedAgent.displayName)", at: 1)
        }

        let selectedSkills = Self.renderSelectedSkills(selectedPromptSkills())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selectedSkillIDs.isEmpty {
            lines.append(selectedSkills)
        }

        let commands = "Commands: \(visibleCommandNamesForCurrentAgent().joined(separator: ", "))"

        lines.append(contentsOf: [
            "Working directory: \(configuration.workingDirectory.path)",
            "",
            commands
        ])

        let startupBox = Self.renderStartupBox(lines: lines)
        AgentOutput.standardError.writeString(startupBox + "\n")
    }

    public func toolCompletionSummary(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> String {
        guard toolCall.name == "local.exec",
              let command = (toolCall.argumentsObject["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !command.isEmpty else {
            return result.summary
        }

        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayCommand = Self.truncatedInline(command, limit: 120)
        guard summary != "exit_code: 0" else {
            return displayCommand
        }
        return "\(displayCommand) (\(summary))"
    }

    public static func renderActiveTools(_ toolNames: [String]) -> String {
        renderActiveTools(toolNames, items: [], selectedKeys: [])
    }

    public static func renderActiveTools(
        _ toolNames: [String],
        items: [TerminalToolSelectionItem],
        selectedKeys: Set<String>
    ) -> String {
        let uniqueToolNames = Set(toolNames).subtracting(AgentProfileStore.featureManagementToolNames)
        guard !uniqueToolNames.isEmpty else {
            return "Active tools: none\n"
        }

        var groupedToolNames = Set<String>()
        var renderedGroups: [String] = []
        let normalizedKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedKeys,
            items: items
        )

        for item in items where normalizedKeys.contains(item.key) {
            let itemToolNames = uniqueToolNames.filter { item.allows(toolName: $0) }
            guard !itemToolNames.isEmpty else {
                continue
            }
            groupedToolNames.formUnion(itemToolNames)
            let concreteToolNames = itemToolNames.filter { toolName in
                !toolName.hasSuffix(".")
            }.sorted()
            let toolCount = concreteToolNames.count
            renderedGroups.append("\(item.title) (\(toolCount))")
        }

        let otherToolCount = uniqueToolNames.subtracting(groupedToolNames).count
        if otherToolCount > 0 {
            renderedGroups.append("Other (\(otherToolCount))")
        }

        guard !renderedGroups.isEmpty else {
            return "Active tools: none\n"
        }
        return "Active tools: \(renderedGroups.joined(separator: ", "))\n"
    }

    public static func renderSelectedSkills(_ skills: [MLXPromptSkill]) -> String {
        guard !skills.isEmpty else {
            return "Selected skills: none\n"
        }

        let renderedSkills = skills
            .map(\.title)
            .joined(separator: ", ")
        return "Selected skills: \(renderedSkills)\n"
    }

    public static func renderToolSelectionUsage() -> String {
        "Usage: /tools [all|none|tool-name|package-name|tool-number]\n"
    }

    public static func renderSkillSelectionUsage() -> String {
        "Usage: /skills [all|none|skill-name|skill-number|install <github-url|local-path>|<github-url|local-path>]\n"
    }

    public static func renderStartupBox(lines: [String]) -> String {
        let columns = terminalColumnCount()
        let bannerLines = mlxCoderHeaderLines
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let contentWidth = max(20, columns - horizontalInset * 2)
        let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"

        var output = bannerLines.map { line in
            "\(linePrefix)\(orange)\(fitBannerLine(line, width: contentWidth))\(reset)"
        }
        for line in lines {
            let splitLines = line.components(separatedBy: .newlines)
            for splitLine in splitLines {
                let wrappedLines = wrapInline(splitLine, width: contentWidth)
                for wrappedLine in wrappedLines {
                    output.append("\(linePrefix)\(orange)\(wrappedLine)\(reset)")
                }
            }
        }
        return output.joined(separator: "\n")
    }

    public static var mlxCoderHeaderLines: [String] {
        [
            "█ █  █   █ █    ██   ██   ██   ██  ███",
            "███  █    █    █    █  █  █ █  █   ██ ",
            "█ █  ██  █ █    ██   ██   ██   ██  █ █",
            "                                      "
        ]
    }

    public static var appVersionDescription: String {
        let version = bundleInfoString("CFBundleShortVersionString") ?? agentVersion
        guard let build = bundleInfoString("CFBundleVersion"),
              build != version else {
            return version
        }
        return "\(version) (\(build))"
    }

    public static func bundleInfoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    public static func terminalColumnCount() -> Int {
        var size = winsize()
        if ioctl(AgentOutput.standardError.fileDescriptor, TIOCGWINSZ, &size) == 0,
           size.ws_col > 0 {
            return Int(size.ws_col)
        }

        if let rawColumns = ProcessInfo.processInfo.environment["COLUMNS"],
           let columns = Int(rawColumns),
           columns > 0 {
            return columns
        }

        return 100
    }

    public static func terminalBoxHorizontalInset(columns _: Int? = nil) -> Int {
        return 0
    }

    public static func fitInline(_ text: String, width: Int) -> String {
        wrapInline(text, width: width).joined(separator: "\n")
    }

    public static func wrapInline(_ text: String, width: Int) -> [String] {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard width > 0, singleLine.count > width else {
            return [singleLine]
        }

        var lines: [String] = []
        var remaining = singleLine[...]
        while remaining.count > width {
            let wrapEnd = remaining.index(remaining.startIndex, offsetBy: width)
            let candidate = remaining[..<wrapEnd]
            let breakIndex = candidate.lastIndex(where: { $0.isWhitespace })
            let lineEnd = breakIndex ?? wrapEnd
            let line = remaining[..<lineEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                lines.append(String(line))
            }
            remaining = remaining[lineEnd...]
                .trimmingCharacters(in: .whitespacesAndNewlines)[...]
        }

        let finalLine = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
        if !finalLine.isEmpty || lines.isEmpty {
            lines.append(finalLine)
        }
        return lines
    }

    public static func fitBannerLine(_ text: String, width: Int) -> String {
        let singleLine = text.replacingOccurrences(of: "\n", with: " ")
        guard width > 3, singleLine.count > width else {
            return singleLine
        }
        return String(singleLine.prefix(width - 3)) + "..."
    }

    public static func padded(_ text: String, width: Int) -> String {
        guard text.count < width else {
            return text
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>) -> Bool {
        allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    public static func truncatedInline(_ text: String, limit: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else {
            return singleLine
        }
        return String(singleLine.prefix(limit - 3)) + "..."
    }

    public func writeDiagnostic(_ message: String) {
        if message.hasPrefix("Generation done:") {
            if !didReceiveMetricsForCurrentPrompt {
                writeChatError("\n\n[mlx-coder] \(compactGenerationSummary(message))\n")
            }
            return
        }

        guard !message.hasPrefix("Remote request:") else {
            return
        }

        writeChatError("\u{1B}[90m[mlx-coder] \(message)\u{1B}[0m\n")
    }

    public func writeThought(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }

        finishAssistantContentFormatting()
        if !isStreamingThoughtOutput {
            isStreamingThoughtOutput = true
            shouldTrimLeadingAssistantContentLineBreaks = false
            assistantContentNeedsLineBreakBeforeTool = false
            let title = AgentOutput.standardErrorIsTerminal
                ? "\u{1B}[90m🤔 Thinking:\u{1B}[0m"
                : "🤔 Thinking:"
            writeChatError("\n\(title)\n")
            thoughtOutputEndsWithNewline = true
        }
        let renderedThought = thoughtMarkdownFormatter.consume(delta)
        writeChatError(
            Self.renderThoughtMarkdown(renderedThought)
        )
        if !renderedThought.isEmpty {
            thoughtOutputEndsWithNewline = renderedThought.hasSuffix("\n")
        }
    }

    public func writeAssistantContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        var content = delta
        if shouldTrimLeadingAssistantContentLineBreaks {
            content = Self.removingLeadingLineBreaks(content)
            guard !content.isEmpty else {
                return
            }
            shouldTrimLeadingAssistantContentLineBreaks = false
        }
        let renderedContent = assistantMarkdownFormatter.consume(content)
        writeChatOutput(renderedContent)
        if !renderedContent.isEmpty {
            assistantContentNeedsLineBreakBeforeTool = !renderedContent.hasSuffix("\n")
        }
    }

    public func finishAssistantContentFormatting() {
        let renderedContent = assistantMarkdownFormatter.finish()
        writeChatOutput(renderedContent)
        if !renderedContent.isEmpty {
            assistantContentNeedsLineBreakBeforeTool = !renderedContent.hasSuffix("\n")
        }
        shouldTrimLeadingAssistantContentLineBreaks = false
    }

    public func writeSubmittedPrompt(_ prompt: String) {
        let renderedLines = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                let prefix = index == 0 ? "> " : "  "
                return "\(prefix)\(line)"
            }
            .joined(separator: "\n")
        writeChatError("\n\(renderedLines)\n")
        assistantContentNeedsLineBreakBeforeTool = false
    }

    public func finishThoughtOutputIfNeeded() {
        guard isStreamingThoughtOutput else {
            return
        }
        let renderedThought = thoughtMarkdownFormatter.finish()
        writeChatError(
            Self.renderThoughtMarkdown(renderedThought)
        )
        if !renderedThought.isEmpty {
            thoughtOutputEndsWithNewline = renderedThought.hasSuffix("\n")
        }
        writeChatError(
            Self.thoughtBoundarySeparator(endsWithNewline: thoughtOutputEndsWithNewline)
        )
        shouldTrimLeadingAssistantContentLineBreaks = true
        assistantContentNeedsLineBreakBeforeTool = false
        thoughtOutputEndsWithNewline = false
        isStreamingThoughtOutput = false
    }

    static func thoughtBoundarySeparator(endsWithNewline: Bool) -> String {
        endsWithNewline ? "\n" : "\n\n"
    }

    static func removingLeadingLineBreaks(_ text: String) -> String {
        guard let firstContentIndex = text.firstIndex(where: { character in
            !character.unicodeScalars.allSatisfy(CharacterSet.newlines.contains)
        }) else {
            return ""
        }
        return String(text[firstContentIndex...])
    }

    func writeChatOutput(_ text: String) {
        AgentOutput.standardOutput.writeString(chatLineInsetApplied(to: text))
    }

    func writeChatError(_ text: String) {
        AgentOutput.standardError.writeString(chatLineInsetApplied(to: text))
    }

    func writeFailureMessage(_ text: String) {
        writeChatError(
            Self.failureMessageColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func writeSystemMessage(_ text: String) {
        writeChatError(
            Self.systemMessageColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func writeFileChangeSummaryMessage(_ text: String) {
        writeChatError(
            Self.fileChangeSummaryColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func writeOperationalMessage(_ text: String) {
        writeChatError(
            Self.operationalMessageColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func chatLineInsetApplied(to text: String) -> String {
        Self.chatLineInsetApplied(
            to: text,
            prefix: chatLineInsetPrefix,
            isAtLineStart: &isAtStartOfChatLine
        )
    }

    var chatLineInsetPrefix: String {
        stdinIsTerminal ? Self.chatLineInsetPrefix : ""
    }

    static func chatLineInsetApplied(
        to text: String,
        prefix: String,
        isAtLineStart: inout Bool
    ) -> String {
        guard !text.isEmpty else {
            return text
        }

        var output = ""
        for character in text {
            if character == "\n" || character == "\r" {
                output.append(character)
                isAtLineStart = true
                continue
            }
            if isAtLineStart {
                if !prefix.isEmpty {
                    output += prefix
                }
                isAtLineStart = false
            }
            output.append(character)
        }
        return output
    }

    static let chatLineInsetPrefix = " "

    static func systemMessageColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        let color = systemMessageANSIColor
        let reset = "\u{1B}[0m"
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : "\(color)\(line)\(reset)"
            }
            .joined(separator: "\n")
    }

    private static let systemMessageANSIColor = "\u{1B}[38;5;179m"

    static func fileChangeSummaryColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        let color = fileChangeSummaryANSIColor
        let reset = "\u{1B}[0m"
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : "\(color)\(line)\(reset)"
            }
            .joined(separator: "\n")
    }

    private static let fileChangeSummaryANSIColor = "\u{1B}[1;38;5;214m"

    static func failureMessageColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        let color = failureMessageANSIColor
        let reset = "\u{1B}[0m"
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : "\(color)\(line)\(reset)"
            }
            .joined(separator: "\n")
    }

    private static let failureMessageANSIColor = "\u{1B}[38;5;203m"

    static func operationalMessageColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        return "\u{1B}[38;5;75m\(text)\u{1B}[0m"
    }

    private static func renderThoughtMarkdown(_ renderedMarkdown: String) -> String {
        guard AgentOutput.standardErrorIsTerminal,
              !renderedMarkdown.isEmpty else {
            return renderedMarkdown
        }

        let gray = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
        var output = gray
        var cursor = renderedMarkdown.startIndex

        while cursor < renderedMarkdown.endIndex {
            guard renderedMarkdown[cursor] == "\u{1B}",
                  renderedMarkdown.index(after: cursor) < renderedMarkdown.endIndex,
                  renderedMarkdown[renderedMarkdown.index(after: cursor)] == "[" else {
                output.append(renderedMarkdown[cursor])
                cursor = renderedMarkdown.index(after: cursor)
                continue
            }

            guard let sequenceEnd = renderedMarkdown[cursor...].firstIndex(of: "m") else {
                output.append(renderedMarkdown[cursor])
                cursor = renderedMarkdown.index(after: cursor)
                continue
            }

            let sequence = String(renderedMarkdown[cursor...sequenceEnd])
            output += dimmedANSISequence(sequence, gray: gray, reset: reset)
            cursor = renderedMarkdown.index(after: sequenceEnd)
        }

        output += reset
        return output
    }

    private static func dimmedANSISequence(
        _ sequence: String,
        gray: String,
        reset: String
    ) -> String {
        guard sequence.hasPrefix("\u{1B}["),
              sequence.hasSuffix("m") else {
            return sequence
        }

        let rawCodes = sequence
            .dropFirst(2)
            .dropLast()
            .split(separator: ";")
            .compactMap { Int(String($0)) }
        guard !rawCodes.isEmpty else {
            return gray
        }

        if rawCodes.contains(0) {
            return reset + gray
        }

        var preservedCodes: [Int] = []
        var index = 0
        while index < rawCodes.count {
            let code = rawCodes[index]
            if code == 38,
               index + 2 < rawCodes.count,
               rawCodes[index + 1] == 5 {
                index += 3
                continue
            }
            if code == 39 || (30...37).contains(code) || (90...97).contains(code) {
                index += 1
                continue
            }
            if [1, 2, 3, 4, 9].contains(code) {
                preservedCodes.append(code)
            }
            index += 1
        }

        preservedCodes.append(90)
        let renderedCodes = preservedCodes
            .map(String.init)
            .joined(separator: ";")
        return "\u{1B}[\(renderedCodes)m"
    }

    public func writeToolCallStarted(_ toolCall: DirectAgentToolCall) {
        guard isDetailedToolOutputEnabled else {
            writeCompactToolCallStarted(toolCall)
            return
        }

        writeToolBlock(Self.detailedToolCallStartedLines(for: toolCall))
    }

    public func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        guard isDetailedToolOutputEnabled,
              activeCompactToolCallID != toolCall.id else {
            writeCompactToolCallCompleted(toolCall, result: result)
            return
        }

        writeToolBlock(Self.detailedToolCallCompletedLines(for: toolCall, result: result))
    }

    public func toggleToolDetailsOutput() {
        if activeCompactToolCallID != nil {
            writeChatError("\n")
            activeCompactToolCallID = nil
            activeCompactToolRenderedRowCount = 0
        }
        isDetailedToolOutputEnabled.toggle()
        writeSystemMessage(
            "Tool details: \(isDetailedToolOutputEnabled ? "full" : "compact")\n"
        )
    }

    private func writeCompactToolCallStarted(_ toolCall: DirectAgentToolCall) {
        let lines = Self.compactToolLines(
            for: toolCall,
            statusIcon: "⏳",
            contentInsetWidth: chatLineInsetPrefix.count
        )
        activeCompactToolCallID = toolCall.id
        activeCompactToolRenderedRowCount = Self.renderedTerminalRowCount(
            for: lines,
            contentInsetWidth: chatLineInsetPrefix.count
        )
        writeCompactToolLines(lines, leadingNewline: consumeToolLeadingLineBreakRequirement())
    }

    private func writeCompactToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        let icon = failed ? "⚠️" : "✅"
        let lines = Self.compactToolLines(
            for: toolCall,
            statusIcon: icon,
            contentInsetWidth: chatLineInsetPrefix.count
        )
        let shouldRewriteActiveLine = activeCompactToolCallID == toolCall.id
            && AgentOutput.standardErrorIsTerminal
        let rewriteRowCount = activeCompactToolRenderedRowCount
        activeCompactToolCallID = nil
        activeCompactToolRenderedRowCount = 0

        if shouldRewriteActiveLine {
            AgentOutput.standardError.writeString("\u{1B}[\(max(1, rewriteRowCount))A\r\u{1B}[J")
        }
        writeCompactToolLines(
            lines,
            leadingNewline: !shouldRewriteActiveLine && consumeToolLeadingLineBreakRequirement()
        )
    }

    private func writeCompactToolLines(
        _ lines: [String],
        leadingNewline: Bool = false,
        terminator: String = "\n"
    ) {
        let reset = "\u{1B}[0m"
        let prefix = leadingNewline ? "\n" : ""
        let lineInset = chatLineInsetPrefix
        let text = lines
            .map { "\r\u{1B}[2K\(lineInset)\(Self.toolANSIColor)\($0)\(reset)" }
            .joined(separator: "\n")
        AgentOutput.standardError.writeString("\(prefix)\(text)\(terminator)")
        assistantContentNeedsLineBreakBeforeTool = false
        isAtStartOfChatLine = terminator.hasSuffix("\n")
    }

    static func compactToolLines(
        for toolCall: DirectAgentToolCall,
        statusIcon: String,
        contentInsetWidth: Int = 0
    ) -> [String] {
        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        let icon = MLXCoderACPBridge.toolIcon(for: toolCall.name)
        guard let target = MLXCoderACPBridge.displayToolTarget(for: toolCall),
              title.hasSuffix(target) else {
            return [compactToolHeaderLine("\(icon)  \(title) \(statusIcon)")]
        }

        let action = title
            .dropLast(target.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            return [compactToolHeaderLine("\(icon)  \(title) \(statusIcon)")]
        }
        return [
            compactToolHeaderLine("\(icon)  \(action):"),
            compactToolStatusLine(
                target: target,
                statusIcon: statusIcon,
                contentInsetWidth: contentInsetWidth
            )
        ]
    }

    private static func compactToolHeaderLine(_ text: String) -> String {
        text
    }

    static func compactToolStatusLine(
        target: String,
        statusIcon: String,
        contentInsetWidth: Int = 0
    ) -> String {
        let columns = max(20, terminalColumnCount() - contentInsetWidth)
        let suffixWidth = displayWidth(statusIcon)
        let textWidthLimit = max(1, columns - suffixWidth - 1)
        let fittedTarget = fitDisplayWidth(target, width: textWidthLimit)
        return "\(fittedTarget) \(statusIcon)"
    }

    private static func renderedTerminalRowCount(
        for lines: [String],
        contentInsetWidth: Int = 0
    ) -> Int {
        let columns = max(1, terminalColumnCount() - contentInsetWidth)
        return lines.reduce(0) { result, line in
            let width = max(1, displayWidth(line))
            return result + max(1, (width + columns - 1) / columns)
        }
    }

    private static func fitDisplayWidth(_ text: String, width: Int) -> String {
        guard displayWidth(text) > width else {
            return text
        }
        guard width > 3 else {
            return String(text.prefix(max(0, width)))
        }

        var output = ""
        var currentWidth = 0
        let ellipsisWidth = 3
        for character in text {
            let characterWidth = displayWidth(String(character))
            guard currentWidth + characterWidth <= width - ellipsisWidth else {
                break
            }
            output.append(character)
            currentWidth += characterWidth
        }
        return output + "..."
    }

    private static func displayWidth(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { result, scalar in
            guard scalar.value >= 0x20 else {
                return result
            }
            return result + (scalar.value >= 0x1100 ? 2 : 1)
        }
    }

    private func writeToolBlock(_ lines: [String]) {
        let reset = "\u{1B}[0m"
        let prefix = consumeToolLeadingLineBreakRequirement() ? "\n" : ""
        let lineInset = chatLineInsetPrefix
        let text = lines
            .map { "\(lineInset)\(Self.renderDetailedToolLine($0))\(reset)" }
            .joined(separator: "\n")
        AgentOutput.standardError.writeString("\(prefix)\(text)\n")
        assistantContentNeedsLineBreakBeforeTool = false
        isAtStartOfChatLine = true
    }

    private static func renderDetailedToolLine(_ line: String) -> String {
        if line.hasPrefix("  ") || line.hasPrefix("    ") {
            return TerminalCodeBlockRenderer.renderLine(line, language: nil)
        }
        return "\(toolANSIColor)\(line)"
    }

    private func consumeToolLeadingLineBreakRequirement() -> Bool {
        let shouldWriteLineBreak = assistantContentNeedsLineBreakBeforeTool
        assistantContentNeedsLineBreakBeforeTool = false
        return shouldWriteLineBreak
    }

    private static let toolANSIColor = "\u{1B}[38;5;208m"
    private static let detailedSnippetLineLimit = 12
    private static let detailedSnippetCharacterLimit = 1_200

    static func detailedToolCallStartedLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        var lines = detailedToolBaseLines(
            for: toolCall,
            statusIcon: "⏳",
            status: "in_progress"
        )
        if isFileMutationTool(toolCall.name) {
            lines.append("change: pending")
        }
        return lines
    }

    static func detailedToolCallCompletedLines(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> [String] {
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        var lines = detailedToolBaseLines(
            for: toolCall,
            statusIcon: failed ? "⚠️" : "✅",
            status: failed ? "failed" : "completed"
        )

        if failed {
            lines.append("error:")
            lines.append(contentsOf: indentedSnippet(result.output))
            return lines
        }

        let changeLines = appliedChangeDetailLines(for: toolCall)
        if !changeLines.isEmpty {
            lines.append(contentsOf: changeLines)
        } else if let summary = compactSummaryLine(result.summary) {
            lines.append("summary: \(summary)")
        }
        return lines
    }

    private static func detailedToolBaseLines(
        for toolCall: DirectAgentToolCall,
        statusIcon: String,
        status: String
    ) -> [String] {
        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        let kind = MLXCoderACPBridge.toolKind(for: toolCall.name)
        let icon = MLXCoderACPBridge.toolIcon(for: toolCall.name)
        var lines = [
            "\(icon)  \(title) \(statusIcon)",
            "status: \(status)",
            "kind: \(kind)"
        ]
        lines.append(contentsOf: toolLocationLines(for: toolCall))
        return lines
    }

    static func appliedChangeDetailLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        let arguments = toolCall.argumentsObject
        switch normalizedMutationToolName(toolCall.name) {
        case "local.writeFile", "XcodeWrite":
            var lines = ["change: write \(targetPath(arguments) ?? "file")"]
            if let content = stringArgument(arguments, keys: ["content", "text"]) {
                lines.append("content:")
                lines.append(contentsOf: indentedSnippet(content))
            }
            return lines
        case "local.append":
            var lines = ["change: append \(targetPath(arguments) ?? "file")"]
            if let content = stringArgument(arguments, keys: ["content", "text"]) {
                lines.append("appended:")
                lines.append(contentsOf: indentedSnippet(content))
            }
            return lines
        case "local.replace", "local.editFile", "XcodeUpdate":
            var lines = ["change: replace \(targetPath(arguments) ?? "file")"]
            if boolArgument(arguments, keys: ["replaceAll", "replace_all"]) == true {
                lines.append("mode: replace all")
            }
            if let oldString = stringArgument(arguments, keys: ["oldString", "old_string"]) {
                lines.append("old:")
                lines.append(contentsOf: indentedSnippet(oldString))
            }
            if let newString = stringArgument(arguments, keys: ["newString", "new_string"]) {
                lines.append("new:")
                lines.append(contentsOf: indentedSnippet(newString))
            }
            return lines
        case "local.multiEdit":
            return multiEditChangeDetailLines(arguments)
        case "local.delete", "XcodeRM":
            return ["change: delete \(targetPath(arguments) ?? "file")"]
        case "local.move", "XcodeMV":
            return [
                "change: move",
                "from: \(stringArgument(arguments, keys: ["sourcePath", "source_path", "from"]) ?? "unknown")",
                "to: \(stringArgument(arguments, keys: ["destinationPath", "destination_path", "to"]) ?? "unknown")"
            ]
        case "local.mkdir":
            return ["change: create directory \(targetPath(arguments) ?? "directory")"]
        default:
            return []
        }
    }

    private static func toolLocationLines(
        for toolCall: DirectAgentToolCall
    ) -> [String] {
        MLXCoderACPBridge.toolLocations(for: toolCall).compactMap { location in
            guard let path = location["path"] as? String,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return "location: \(path)"
        }
    }

    private static func multiEditChangeDetailLines(_ arguments: [String: Any]) -> [String] {
        let edits = arrayObjectArgument(arguments, keys: ["edits"])
        var lines = [
            "change: edit \(targetPath(arguments) ?? "file") (\(edits.count) edits)"
        ]
        for (index, edit) in edits.prefix(3).enumerated() {
            lines.append("edit \(index + 1):")
            if let oldString = stringArgument(edit, keys: ["oldString", "old_string"]) {
                lines.append("  old:")
                lines.append(contentsOf: indentedSnippet(oldString, indentation: "    "))
            }
            if let newString = stringArgument(edit, keys: ["newString", "new_string"]) {
                lines.append("  new:")
                lines.append(contentsOf: indentedSnippet(newString, indentation: "    "))
            }
        }
        if edits.count > 3 {
            lines.append("... \(edits.count - 3) more edits")
        }
        return lines
    }

    private static func isFileMutationTool(_ toolName: String) -> Bool {
        switch normalizedMutationToolName(toolName) {
        case "local.writeFile", "local.append", "local.replace",
             "local.editFile", "local.multiEdit", "local.delete",
             "local.move", "local.mkdir", "XcodeWrite", "XcodeUpdate",
             "XcodeRM", "XcodeMV":
            return true
        default:
            return false
        }
    }

    private static func normalizedMutationToolName(_ toolName: String) -> String {
        let trimmedName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName.hasPrefix("xcode.") {
            return String(trimmedName.dropFirst("xcode.".count))
        }
        return trimmedName
    }

    private static func targetPath(_ arguments: [String: Any]) -> String? {
        stringArgument(
            arguments,
            keys: [
                "file_path",
                "filePath",
                "file",
                "path",
                "directoryPath",
                "directory_path"
            ]
        )
    }

    private static func stringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String,
               let normalizedValue = value.nilIfBlank {
                return normalizedValue
            }
            if let value = arguments[key] as? JSONValue,
               let normalizedValue = value.stringValue?.nilIfBlank {
                return normalizedValue
            }
        }
        return nil
    }

    private static func boolArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            if let value = arguments[key] as? Bool {
                return value
            }
            if let value = arguments[key] as? JSONValue {
                return value.boolValue
            }
        }
        return nil
    }

    private static func arrayObjectArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [[String: Any]] {
        for key in keys {
            if let value = arguments[key] as? [[String: Any]] {
                return value
            }
            if let value = arguments[key] as? [Any] {
                return value.compactMap { $0 as? [String: Any] }
            }
            if let value = arguments[key] as? JSONValue,
               case let .array(items) = value {
                return items.compactMap { item in
                    guard case let .object(object) = item else {
                        return nil
                    }
                    return object.mapValues(\.jsonObject)
                }
            }
        }
        return []
    }

    private static func compactSummaryLine(_ text: String) -> String? {
        let summary = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .nilIfBlank
        guard let summary else {
            return nil
        }
        if summary.count <= 160 {
            return summary
        }
        return "\(summary.prefix(157))..."
    }

    private static func indentedSnippet(
        _ text: String,
        indentation: String = "  "
    ) -> [String] {
        var snippet = text.trimmingCharacters(in: .newlines)
        if snippet.count > detailedSnippetCharacterLimit {
            snippet = String(snippet.prefix(detailedSnippetCharacterLimit))
        }
        let lines = snippet
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let visibleLines = Array(lines.prefix(detailedSnippetLineLimit))
        var output = visibleLines.isEmpty
            ? ["\(indentation)<empty>"]
            : visibleLines.map { "\(indentation)\($0)" }
        if lines.count > visibleLines.count || text.count > snippet.count {
            output.append("\(indentation)... truncated")
        }
        return output
    }

    public func writeMetricsStatus(_ metrics: DirectAgentGenerationMetrics) {
        _ = statusBar.update(metrics: metrics)
        guard Self.shouldPrintMetricsForAutomation(),
              metrics.completionTokensPerSecond != nil else {
            return
        }
        writeChatError(
            "\n[mlx-coder] \(Self.metricsSummary(metrics))\n"
        )
    }

    public func writeContextWindowStatus(_ status: DirectAgentContextWindowStatus) {
        _ = statusBar.update(contextWindow: status)
    }

    public func compactGenerationSummary(_ message: String) -> String {
        if let range = message.range(of: "\n  Cache:") {
            return String(message[..<range.lowerBound])
        }
        if let range = message.range(of: "\nCache:") {
            return String(message[..<range.lowerBound])
        }
        if let range = message.range(of: "; cache ") {
            return String(message[..<range.lowerBound])
        }
        return message
    }

    public static func shouldPrintMetricsForAutomation() -> Bool {
        ProcessInfo.processInfo.environment["MLX_CODER_PRINT_METRICS"] == "1"
    }

    public static func metricsSummary(_ metrics: DirectAgentGenerationMetrics) -> String {
        let total = metrics.totalTokenCount.map(String.init) ?? "--"
        let prefill = metrics.promptTokenCount.map(String.init) ?? "--"
        let cache = metrics.cachedPromptTokenCount.map(String.init) ?? "--"
        let output = metrics.completionTokenCount.map(String.init) ?? "--"
        let promptRate = metrics.promptTokensPerSecond.map {
            String(format: "%.1f", $0)
        } ?? "--"
        let generationRate = metrics.completionTokensPerSecond.map {
            String(format: "%.1f", $0)
        } ?? "--"
        let duration = metrics.responseDurationSeconds.map(Self.durationText) ?? "--"
        return "tokens \(total) | pre \(prefill) | cache \(cache) | prompt \(promptRate)/s | out \(output) | gen \(generationRate)/s | time \(duration)"
    }

    public static func durationText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else {
            return "--"
        }
        if value < 60 {
            return String(format: "%.1fs", value)
        }
        let roundedSeconds = Int(value.rounded())
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60
        if minutes < 60 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        let hours = minutes / 60
        return String(format: "%d:%02d:%02d", hours, minutes % 60, seconds)
    }
}
