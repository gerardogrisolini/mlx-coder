//
//  TerminalChat+SubAgents.swift
//  mlx-coder
//
//  TUI overview for delegated sub-agent state.
//

import Foundation

extension TerminalChat {
    public func handleSubAgentsCommand(_ command: String) async {
        let argument = String(command.dropFirst("/subagents".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch argument {
        case "", "on", "show":
            isSubAgentOverviewVisible = true
            lastRenderedSubAgentOverviewSignature = nil
            startSubAgentOverviewRefreshLoop()
            await renderSubAgentOverview(force: true)
        case "once", "now", "status":
            await renderSubAgentOverview(force: true, rememberSignature: false)
        case "off", "hide":
            isSubAgentOverviewVisible = false
            lastRenderedSubAgentOverviewSignature = nil
            stopSubAgentOverviewRefreshLoop()
            AgentOutput.standardError.writeString("Sub-agent overview hidden.\n")
        default:
            AgentOutput.standardError.writeString(
                "Usage: /subagents [on|off|once]\n"
            )
        }
    }

    public func publishSubAgentOverviewIfVisible(
        relatedToolName: String? = nil
    ) async {
        guard isSubAgentOverviewVisible else {
            return
        }
        if let relatedToolName,
           !DirectSubAgentRuntime.isSubAgentToolName(relatedToolName) {
            return
        }

        await renderSubAgentOverview(force: false)
    }

    public func renderSubAgentOverview(
        force: Bool,
        rememberSignature: Bool = true
    ) async {
        let snapshots = await sessionRunner.subAgentSnapshots()
        let signature = Self.subAgentOverviewSignature(snapshots)
        guard force || signature != lastRenderedSubAgentOverviewSignature else {
            return
        }

        if rememberSignature {
            lastRenderedSubAgentOverviewSignature = signature
        }

        AgentOutput.standardError.writeString(
            "\n" + Self.renderSubAgentOverview(snapshots) + "\n"
        )
    }

    public func startSubAgentOverviewRefreshLoop() {
        guard subAgentOverviewRefreshTask == nil else {
            return
        }

        subAgentOverviewRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self,
                      self.isSubAgentOverviewVisible else {
                    continue
                }
                await self.renderSubAgentOverview(force: false)
            }
        }
    }

    public func stopSubAgentOverviewRefreshLoop() {
        subAgentOverviewRefreshTask?.cancel()
        subAgentOverviewRefreshTask = nil
    }

    public static func renderSubAgentOverview(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        let activeCount = snapshots.filter(\.pending).count
        let completedCount = snapshots.filter { snapshot in
            snapshot.status == .idle && snapshot.latestOutput?.nilIfBlank != nil
        }.count
        let failedCount = snapshots.filter { $0.status == .failed }.count
        let closedCount = snapshots.filter { $0.status == .closed }.count

        var lines = [
            "Agents \(snapshots.count) | active \(activeCount) | completed \(completedCount) | failed \(failedCount) | closed \(closedCount)"
        ]

        if snapshots.isEmpty {
            lines.append("No delegated sub-agents.")
            return renderSubAgentOverviewBox(lines: lines)
        }

        for snapshot in snapshots {
            lines.append("")
            lines.append(renderSubAgentHeader(snapshot))
            lines.append("  id: \(snapshot.id)")
            if !snapshot.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("  role: \(snapshot.role)")
            }
            if let detail = renderSubAgentDetail(snapshot) {
                lines.append(detail)
            }
        }

        return renderSubAgentOverviewBox(lines: lines)
    }

    private static func renderSubAgentHeader(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let status = displayStatus(for: snapshot)
        let age = relativeAgeText(since: snapshot.updatedAt)
        let name = snapshot.name.nilIfBlank ?? snapshot.id
        let marker = coloredStatusMarker(for: snapshot)
        return "\(marker) \(name)  \(status) | \(snapshot.isolationMode.rawValue) | updated \(age)"
    }

    private static func renderSubAgentDetail(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String? {
        if let latestError = snapshot.latestError?.nilIfBlank {
            return "  error: \(truncatedInline(latestError, limit: 180))"
        }

        guard let latestOutput = snapshot.latestOutput?.nilIfBlank else {
            if snapshot.pending {
                return "  working: pending response"
            }
            return nil
        }

        let title = snapshot.pending ? "latest output" : "result"
        return "  \(title): \(truncatedInline(latestOutput, limit: 180))"
    }

    private static func displayStatus(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        if snapshot.status == .idle,
           snapshot.latestOutput?.nilIfBlank != nil {
            return "completed"
        }
        return snapshot.status.rawValue
    }

    private static func coloredStatusMarker(
        for snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        let marker = "●"
        guard AgentOutput.standardErrorIsTerminal else {
            return marker
        }

        let color: String
        switch snapshot.status {
        case .queued:
            color = "\u{1B}[33m"
        case .running:
            color = "\u{1B}[38;5;208m"
        case .idle:
            color = snapshot.latestOutput?.nilIfBlank == nil
                ? "\u{1B}[90m"
                : "\u{1B}[32m"
        case .failed:
            color = "\u{1B}[31m"
        case .closed:
            color = "\u{1B}[90m"
        }
        return "\(color)\(marker)\u{1B}[0m"
    }

    private static func renderSubAgentOverviewBox(lines: [String]) -> String {
        let columns = terminalColumnCount()
        let horizontalInset = terminalBoxHorizontalInset(columns: columns)
        let boxWidth = max(24, columns - horizontalInset * 2)
        let contentWidth = max(20, boxWidth - 4)
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let linePrefix = String(repeating: " ", count: horizontalInset)
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"

        var output = [
            "\(linePrefix)\(orange)┌\(horizontalRule)┐\(reset)",
            "\(linePrefix)\(orange)│\(reset) \(padded(fitInline("Sub-Agents", width: contentWidth), width: contentWidth)) \(orange)│\(reset)",
            "\(linePrefix)\(orange)├\(horizontalRule)┤\(reset)"
        ]
        for line in lines {
            let fittedLine = padded(fitInline(line, width: contentWidth), width: contentWidth)
            output.append("\(linePrefix)\(orange)│\(reset) \(fittedLine) \(orange)│\(reset)")
        }
        output.append("\(linePrefix)\(orange)└\(horizontalRule)┘\(reset)")
        return output.joined(separator: "\n")
    }

    private static func subAgentOverviewSignature(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        snapshots.map { snapshot in
            [
                snapshot.id,
                snapshot.name,
                snapshot.role,
                snapshot.isolationMode.rawValue,
                snapshot.status.rawValue,
                snapshot.pending ? "pending" : "idle",
                "\(snapshot.updatedAt.timeIntervalSince1970)",
                snapshot.latestOutput?.nilIfBlank ?? "",
                snapshot.latestError?.nilIfBlank ?? ""
            ].joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }

    private static func relativeAgeText(since date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date).rounded()))
        if seconds < 60 {
            return "\(seconds)s ago"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        return "\(hours / 24)d ago"
    }
}
