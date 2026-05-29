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
        let allowedToolNames = await selectedAllowedToolNames()
        didPrintActiveTools = true

        var lines = [
            "Version: \(Self.appVersionDescription)",
            Self.renderSelectedToolGroups(selectedToolGroups)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            Self.renderActiveTools(Array(allowedToolNames))
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

        lines.append(contentsOf: [
            "Working directory: \(configuration.workingDirectory.path)",
            "",
            "Commands: /help, /models, /agents, /tools, /skills, /attach, /changes, /undo, /subagents, /clear, /exit"
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
        guard !toolNames.isEmpty else {
            return "Active tools: none\n"
        }

        let uniqueToolNames = Set(toolNames)
        var groupedToolNames = Set<String>()
        var renderedGroups: [String] = []
        for group in TerminalToolGroup.allCases {
            let groupToolNames = uniqueToolNames.filter { toolName in
                group.allows(toolName: toolName)
            }
            guard !groupToolNames.isEmpty else {
                continue
            }
            groupedToolNames.formUnion(groupToolNames)
            let concreteToolNames = groupToolNames.filter { toolName in
                !toolName.hasSuffix(".")
            }
            let toolCount = concreteToolNames.isEmpty
                ? groupToolNames.count
                : concreteToolNames.count
            renderedGroups.append("\(group.displayTitle) (\(toolCount))")
        }

        let otherToolCount = uniqueToolNames.subtracting(groupedToolNames).count
        if otherToolCount > 0 {
            renderedGroups.append("Other (\(otherToolCount))")
        }

        return "Active tools: \(renderedGroups.joined(separator: ", "))\n"
    }

    public static func renderSelectedToolGroups(_ groups: Set<TerminalToolGroup>) -> String {
        guard !groups.isEmpty else {
            return "Selected tool groups: none\n"
        }
        let renderedGroups = TerminalToolGroup.allCases
            .filter { groups.contains($0) }
            .map(\.displayTitle)
            .joined(separator: ", ")
        return "Selected tool groups: \(renderedGroups)\n"
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
        let groups = TerminalToolGroup.allCases
            .map(\.rawValue)
            .joined(separator: ", ")
        return "Usage: /tools [all|none|\(groups)]\n"
    }

    public static func renderSkillSelectionUsage() -> String {
        "Usage: /skills [all|none|skill-name|skill-number]\n"
    }

    public static func renderStartupBox(lines: [String]) -> String {
        let columns = terminalColumnCount()
        let bannerLines = mlxCoderHeaderLines
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let boxWidth = max(24, columns - horizontalInset * 2)
        let contentWidth = max(20, boxWidth - 4)
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"

        var output = bannerLines.map { line in
            let fittedLine = padded(fitBannerLine(line, width: boxWidth), width: boxWidth)
            return fittedLine
        }
        output.append("\(linePrefix)\(orange)┌\(horizontalRule)┐\(reset)")
        for line in lines {
            let fittedLine = padded(fitInline(line, width: contentWidth), width: contentWidth)
            output.append("\(linePrefix)\(orange)│\(reset) \(fittedLine) \(orange)│\(reset)")
        }
        output.append("\(linePrefix)\(orange)└\(horizontalRule)┘\(reset)")
        return output.joined(separator: "\n")
    }

    public static var mlxCoderHeaderLines: [String] {
        [
            " █   █   █    █   █      ██    ██    ███    ███   ███",
            " █ █ █   █      █    |  █     █  █   █  █   ██    ███",
            " █   █   █      █    |  █     █  █   █  █   █     █ ",
            " █   █   ███  █   █      ██    ██    ███    ███   █ █"
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
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard width > 3, singleLine.count > width else {
            return singleLine
        }
        return String(singleLine.prefix(width - 3)) + "..."
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

        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        let kind = MLXCoderACPBridge.toolKind(for: toolCall.name)
        var lines = [
            "⚙️  \(title) ⏳",
            "status: in_progress",
            "kind: \(kind)",
            "id: \(toolCall.id)"
        ]
        lines.append(contentsOf: Self.toolLocationLines(for: toolCall))
        lines.append("rawInput:")
        lines.append(contentsOf: Self.indentedBlock(toolCall.argumentsJSON))

        writeToolBlock(lines)
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

        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        let kind = MLXCoderACPBridge.toolKind(for: toolCall.name)
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        let statusIcon = failed ? "⚠️" : "✅"
        var lines = [
            "⚙️  \(title) \(statusIcon)",
            "status: \(failed ? "failed" : "completed")",
            "kind: \(kind)",
            "id: \(toolCall.id)"
        ]
        lines.append(contentsOf: Self.toolLocationLines(for: toolCall))

        let summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            lines.append("rawOutput.summary: \(summary)")
        }

        lines.append("rawOutput.output:")
        lines.append(contentsOf: Self.indentedBlock(result.output))

        writeToolBlock(lines)
    }

    public func toggleToolDetailsOutput() {
        if activeCompactToolCallID != nil {
            writeChatError("\n")
            activeCompactToolCallID = nil
            activeCompactToolRenderedRowCount = 0
        }
        isDetailedToolOutputEnabled.toggle()
        writeChatError(
            "\n[mlx-coder] Tool details: \(isDetailedToolOutputEnabled ? "full" : "compact")\n"
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

    private static func compactToolLines(
        for toolCall: DirectAgentToolCall,
        statusIcon: String,
        contentInsetWidth: Int = 0
    ) -> [String] {
        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        guard let target = MLXCoderACPBridge.displayToolTarget(for: toolCall),
              title.hasSuffix(target) else {
            return [compactToolHeaderLine("⚙️  \(title) \(statusIcon)")]
        }

        let action = title
            .dropLast(target.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            return [compactToolHeaderLine("⚙️  \(title) \(statusIcon)")]
        }
        return [
            compactToolHeaderLine("⚙️  \(action):"),
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

    private static func compactToolStatusLine(
        target: String,
        statusIcon: String,
        contentInsetWidth: Int = 0
    ) -> String {
        rightAlignedSuffix(
            text: target,
            suffix: statusIcon,
            contentInsetWidth: contentInsetWidth
        )
    }

    private static func rightAlignedSuffix(
        text: String,
        suffix: String,
        contentInsetWidth: Int = 0
    ) -> String {
        let columns = max(20, terminalColumnCount() - contentInsetWidth)
        let suffixWidth = displayWidth(suffix)
        let textWidthLimit = max(1, columns - suffixWidth - 1)
        let fittedText = fitDisplayWidth(text, width: textWidthLimit)
        let spacing = columns - displayWidth(fittedText) - suffixWidth
        return fittedText + String(repeating: " ", count: max(1, spacing)) + suffix
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
            .map { "\(lineInset)\(Self.toolANSIColor)\($0)\(reset)" }
            .joined(separator: "\n")
        AgentOutput.standardError.writeString("\(prefix)\(text)\n")
        assistantContentNeedsLineBreakBeforeTool = false
        isAtStartOfChatLine = true
    }

    private func consumeToolLeadingLineBreakRequirement() -> Bool {
        let shouldWriteLineBreak = assistantContentNeedsLineBreakBeforeTool
        assistantContentNeedsLineBreakBeforeTool = false
        return shouldWriteLineBreak
    }

    private static let toolANSIColor = "\u{1B}[38;5;208m"

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

    private static func indentedBlock(_ text: String) -> [String] {
        let trimmedText = text.trimmingCharacters(in: .newlines)
        guard !trimmedText.isEmpty else {
            return ["  <empty>"]
        }
        return trimmedText
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
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
