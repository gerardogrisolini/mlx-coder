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

public extension TerminalChat {
    public func printActiveToolsIfNeeded() async {
        guard !didPrintActiveTools else {
            return
        }
        didPrintActiveTools = true
        await printToolSelectionStatus()
    }

    public func printStartupSummary(loadedModelID: String) async {
        let allowedToolNames = await selectedAllowedToolNames()
        didPrintActiveTools = true

        var lines = [
            "Version: \(Self.appVersionDescription)",
            "Loading model...",
            "Loaded model: \(loadedModelDisplayTitle(loadedModelID))",
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
            "Commands: /help, /models, /agents, /tools, /skills, /clear, /exit"
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
            renderedGroups.append("\(group.displayTitle) (\(groupToolNames.count))")
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
        let contentWidth = max(20, columns - 4)
        let horizontalRule = String(repeating: "─", count: contentWidth + 2)
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"

        var output = bannerLines.map { line in
            let fittedLine = padded(fitBannerLine(line, width: contentWidth + 4), width: contentWidth + 4)
            return fittedLine
        }
        output.append("\(orange)╭\(horizontalRule)╮\(reset)")
        for line in lines {
            let fittedLine = padded(fitInline(line, width: contentWidth), width: contentWidth)
            output.append("\(orange)│\(reset) \(fittedLine) \(orange)│\(reset)")
        }
        output.append("\(orange)╰\(horizontalRule)╯\(reset)")
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
                AgentOutput.standardError.writeString("\n\n[mlx-coder] \(compactGenerationSummary(message))\n")
            }
            return
        }

        guard !message.hasPrefix("Remote request:") else {
            return
        }

        AgentOutput.standardError.writeString("\u{1B}[90m[mlx-coder] \(message)\u{1B}[0m\n")
    }

    public func writeThought(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }

        if !isStreamingThoughtOutput {
            AgentOutput.standardError.writeString("\n")
            isStreamingThoughtOutput = true
            AgentOutput.standardError.writeString("\u{1B}[90mthinking:\n\(delta)\u{1B}[0m")
        } else {
            AgentOutput.standardError.writeString("\u{1B}[90m\(delta)\u{1B}[0m")
        }
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
        AgentOutput.standardError.writeString("\n\(renderedLines)\n")
    }

    public func finishThoughtOutputIfNeeded() {
        guard isStreamingThoughtOutput else {
            return
        }
        AgentOutput.standardError.writeString("\n")
        isStreamingThoughtOutput = false
    }

    public func writeToolCallStarted(_ toolCall: DirectAgentToolCall) {
        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        let kind = MLXCoderACPBridge.toolKind(for: toolCall.name)
        var lines = [
            "[tool] \(title)",
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
        let title = MLXCoderACPBridge.toolTitle(for: toolCall)
        let kind = MLXCoderACPBridge.toolKind(for: toolCall.name)
        let failed = result.output
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
        var lines = [
            "[tool] \(title)",
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

    private func writeToolBlock(_ lines: [String]) {
        let toolColor = "\u{1B}[38;5;81m"
        let reset = "\u{1B}[0m"
        let text = lines
            .map { "\(toolColor)\($0)\(reset)" }
            .joined(separator: "\n")
        AgentOutput.standardError.writeString("\n\(text)\n")
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
        AgentOutput.standardError.writeString(
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
