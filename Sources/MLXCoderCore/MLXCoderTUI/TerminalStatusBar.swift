//
//  Generated split from MLXCoder.swift
//  mlx-coder
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public final class TerminalStatusBar: @unchecked Sendable {
    private struct InputPanelState {
        let text: String
        let cursorIndex: Int
        let modeText: String
        let helpText: String
        let suggestionLines: [String]
    }

    private let isEnabled: Bool
    private let output: FileHandle?
    private let lock = NSLock()
    private var isStarted = false
    private var row = 0
    private var columns = 0
    private var isProcessing = false
    private var spinnerIndex = 0
    private var spinnerTimer: DispatchSourceTimer?
    private var resizeSignalSource: DispatchSourceSignal?
    private var resizeGeneration = 0
    private var inputPanelState: InputPanelState?
    private var latestModelID: String?
    private var latestMetrics: DirectAgentGenerationMetrics?
    private var latestContextWindow: DirectAgentContextWindowStatus?
    private static let spinnerFrames = ["-", "\\", "|", "/"]
    private static let inputPanelChromeRows = 3
    private static let minimumScrollableRows = 2
    private static let standaloneStatusRows = 3
    private static let attachedStatusRows = 2

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        self.output = Self.openControllingTerminal()
    }

    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard isEnabled, !isStarted, output != nil else {
            return isStarted
        }
        guard configureTerminalLocked() else {
            return false
        }
        isStarted = true
        writeLocked("\u{1B}[?25l")
        startResizeSignalSourceLocked()
        if isProcessing {
            startSpinnerTimerLocked()
        }
        renderLocked()
        return true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isStarted else {
            return
        }
        stopSpinnerTimerLocked()
        stopResizeSignalSourceLocked()
        clearLocked()
        writeLocked("\u{1B}[r\u{1B}[?25h")
        isStarted = false
    }

    public func updateInputPanel(
        text: String,
        cursorIndex: Int,
        modeText: String,
        helpText: String,
        suggestionLines: [String] = []
    ) {
        lock.lock()
        defer { lock.unlock() }

        let boundedCursorIndex = min(max(0, cursorIndex), text.count)
        let hadInputPanel = inputPanelState != nil
        let oldReservedRows = isStarted ? reservedBottomRowsLocked() : 0
        inputPanelState = InputPanelState(
            text: text,
            cursorIndex: boundedCursorIndex,
            modeText: modeText,
            helpText: helpText,
            suggestionLines: Array(suggestionLines.prefix(6))
        )
        guard isStarted else {
            return
        }
        let newReservedRows = reservedBottomRowsLocked()
        if !hadInputPanel || oldReservedRows != newReservedRows {
            clearReservedRowsLocked(count: max(oldReservedRows, newReservedRows))
            writeScrollRegionLocked(moveCursorToPrompt: true)
        }
        renderLocked()
    }

    public func clearInputPanel() {
        lock.lock()
        defer { lock.unlock() }

        guard inputPanelState != nil else {
            return
        }
        let oldReservedRows = reservedBottomRowsLocked()
        inputPanelState = nil
        guard isStarted else {
            return
        }
        clearReservedRowsLocked(count: oldReservedRows)
        writeScrollRegionLocked(moveCursorToPrompt: true)
        renderLocked()
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }

        latestMetrics = nil
        latestContextWindow = nil
        latestModelID = nil
        isProcessing = false
        spinnerIndex = 0
        stopSpinnerTimerLocked()
        guard isStarted else {
            return
        }
        renderLocked()
    }

    public func setProcessing(_ isProcessing: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard self.isProcessing != isProcessing else {
            return
        }
        self.isProcessing = isProcessing
        spinnerIndex = 0
        if isProcessing {
            startSpinnerTimerLocked()
        } else {
            stopSpinnerTimerLocked()
        }
        guard isStarted else {
            return
        }
        renderLocked()
    }

    @discardableResult
    public func update(modelID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        latestModelID = modelID
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }

    @discardableResult
    public func update(metrics: DirectAgentGenerationMetrics) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        latestMetrics = mergedMetrics(
            current: latestMetrics,
            update: metrics
        )
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }

    @discardableResult
    public func update(contextWindow: DirectAgentContextWindowStatus) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        latestContextWindow = contextWindow
        guard isStarted else {
            return false
        }
        renderLocked()
        return true
    }

    public func currentContextWindowStatus() -> DirectAgentContextWindowStatus? {
        lock.lock()
        defer { lock.unlock() }

        if let latestContextWindow {
            return latestContextWindow
        }
        guard let latestModelID else {
            return nil
        }
        return DirectAgentContextWindowStatus(
            usedTokens: latestMetrics?.totalTokenCount,
            maxTokens: nil,
            modelID: latestModelID,
            isApproximate: true
        )
    }

    public func reservedRowsForOverlay() -> Int {
        lock.lock()
        defer { lock.unlock() }

        guard isStarted else {
            return 0
        }
        return reservedBottomRowsLocked()
    }

    private func configureTerminalLocked(moveCursorToPrompt: Bool = true) -> Bool {
        guard let output,
              let geometry = Self.currentTerminalGeometry(fileDescriptor: output.fileDescriptor),
              geometry.rows >= minimumRowsLocked(),
              geometry.columns >= 40 else {
            return false
        }

        row = geometry.rows
        columns = geometry.columns
        writeScrollRegionLocked(moveCursorToPrompt: moveCursorToPrompt)
        return true
    }

    private func refreshTerminalGeometryLocked() -> Bool {
        guard let output,
              let geometry = Self.currentTerminalGeometry(fileDescriptor: output.fileDescriptor),
              geometry.rows >= minimumRowsLocked(),
              geometry.columns >= 40 else {
            return false
        }
        guard geometry.rows != row || geometry.columns != columns else {
            return true
        }

        clearLocked(row: row)
        row = geometry.rows
        columns = geometry.columns
        redrawTerminalLocked(moveCursorToPrompt: true)
        return true
    }

    private func writeScrollRegionLocked(moveCursorToPrompt: Bool) {
        let scrollBottom = max(1, row - reservedBottomRowsLocked())
        let scrollTop = 1
        var sequence = "\u{1B}[\(scrollTop);\(scrollBottom)r"
        if moveCursorToPrompt {
            sequence += "\u{1B}[\(scrollBottom);1H"
        }
        writeLocked(sequence)
    }

    private func redrawTerminalLocked(moveCursorToPrompt: Bool) {
        writeLocked("\u{1B}[r\u{1B}[2J\u{1B}[H")
        writeScrollRegionLocked(moveCursorToPrompt: moveCursorToPrompt)
    }

    private func renderLocked() {
        guard row > 0, columns > 0 else {
            return
        }

        let sequence = "\u{1B}[?25l" + inputPanelRenderSequenceLocked() + statusRenderSequenceLocked()
        writeLocked(sequence)
    }

    private func inputPanelRenderSequenceLocked() -> String {
        guard let inputPanelState else {
            return ""
        }

        let topRow = max(1, row - reservedBottomRowsLocked() + 1)
        let startColumn = statusBoxStartColumnLocked()
        let boxWidth = statusBoxWidthLocked()
        let orange = "\u{1B}[38;5;208m"
        let dim = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let contentWidth = statusBoxContentWidthLocked()
        let inputRows = inputPanelDisplayRowsLocked(
            text: inputPanelState.text,
            cursorIndex: inputPanelState.cursorIndex
        )
        let suggestionRows = inputPanelSuggestionRowsLocked(
            lines: inputPanelState.suggestionLines
        )
        let modeLine = Self.padded(
            Self.fit(
                "\(inputPanelState.modeText) · \(inputPanelState.helpText)",
                width: contentWidth
            ),
            width: contentWidth
        )

        let inputSequence = inputRows.enumerated().map { offset, inputRow in
            [
                "\u{1B}[\(topRow + offset + 1);\(startColumn)H",
                "\u{1B}[2K",
                orange,
                "│",
                reset,
                " ",
                inputRow,
                " ",
                orange,
                "│",
                reset
            ].joined()
        }.joined()
        let suggestionSequence = suggestionRows.enumerated().map { offset, suggestionRow in
            [
                "\u{1B}[\(topRow + inputRows.count + offset + 1);\(startColumn)H",
                "\u{1B}[2K",
                orange,
                "│",
                reset,
                " ",
                dim,
                suggestionRow,
                reset,
                " ",
                orange,
                "│",
                reset
            ].joined()
        }.joined()
        let modeRow = topRow + inputRows.count + suggestionRows.count + 1
        let parts = [
            "\u{1B}7",
            "\u{1B}[\(topRow);\(startColumn)H",
            "\u{1B}[2K",
            orange,
            "┌",
            horizontalRule,
            "┐",
            reset,
            inputSequence,
            suggestionSequence,
            "\u{1B}[\(modeRow);\(startColumn)H",
            "\u{1B}[2K",
            orange,
            "│",
            reset,
            " ",
            dim,
            modeLine,
            reset,
            " ",
            orange,
            "│",
            reset,
            "\u{1B}[\(modeRow + 1);\(startColumn)H",
            "\u{1B}[2K",
            orange,
            "├",
            horizontalRule,
            "┤",
            reset,
            "\u{1B}8"
        ]
        return parts.joined()
    }

    private func statusRenderSequenceLocked() -> String {
        let startColumn = statusBoxStartColumnLocked()
        let boxWidth = statusBoxWidthLocked()
        let contentWidth = statusBoxContentWidthLocked()
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let text = Self.fit(statusTextLocked(), width: contentWidth)
        let padding = max(0, contentWidth - text.count)
        let isAttachedToInputPanel = inputPanelState != nil
        var sequence = "\u{1B}7"
        if !isAttachedToInputPanel {
            sequence += "\u{1B}[\(max(1, row - 2));\(startColumn)H"
                + "\u{1B}[2K"
                + orange
                + "┌"
                + horizontalRule
                + "┐"
                + reset
        }
        sequence += "\u{1B}[\(max(1, row - 1));\(startColumn)H"
            + "\u{1B}[2K"
            + orange
            + "│"
            + reset
            + " "
            + text
            + String(repeating: " ", count: padding)
            + " "
            + orange
            + "│"
            + reset
            + "\u{1B}[\(row);\(startColumn)H"
            + "\u{1B}[2K"
            + orange
            + "└"
            + horizontalRule
            + "┘"
            + reset
            + "\u{1B}8"
        return sequence
    }

    private func clearLocked() {
        clearLocked(row: row)
    }

    private func clearLocked(row: Int) {
        guard row > 0 else {
            return
        }
        clearReservedRowsLocked(count: reservedBottomRowsLocked(), bottomRow: row)
    }

    private func clearReservedRowsLocked(count: Int, bottomRow: Int? = nil) {
        let resolvedBottomRow = bottomRow ?? row
        guard resolvedBottomRow > 0, count > 0 else {
            return
        }
        let firstRow = max(1, resolvedBottomRow - count + 1)
        var sequence = "\u{1B}7"
        for rowIndex in firstRow...resolvedBottomRow {
            sequence += "\u{1B}[\(rowIndex);1H\u{1B}[2K"
        }
        sequence += "\u{1B}8"
        writeLocked(sequence)
    }

    private func reservedBottomRowsLocked() -> Int {
        guard let inputPanelState else {
            return Self.standaloneStatusRows
        }
        return Self.inputPanelChromeRows
            + inputPanelDisplayLineCountLocked(
                text: inputPanelState.text,
                cursorIndex: inputPanelState.cursorIndex
            )
            + inputPanelState.suggestionLines.count
            + Self.attachedStatusRows
    }

    private func minimumRowsLocked() -> Int {
        let minimumReservedRows: Int
        if inputPanelState == nil {
            minimumReservedRows = Self.standaloneStatusRows
        } else {
            minimumReservedRows = Self.inputPanelChromeRows + Self.attachedStatusRows + 1
        }
        return max(5, minimumReservedRows + Self.minimumScrollableRows)
    }

    private func statusTextLocked() -> String {
        let tokensUsed = latestContextWindow?.usedTokens
            ?? latestMetrics?.totalTokenCount
        let tokenWindowText = Self.tokenWindowText(
            usedTokens: latestContextWindow?.usedTokens,
            metricUsedTokens: tokensUsed,
            maxTokens: latestContextWindow?.maxTokens
        )
        let prefillText = latestMetrics?.promptTokenCount.map(Self.tokenCountText) ?? "--"
        let promptRateText = latestMetrics?.promptTokensPerSecond.map(Self.rateText) ?? "--"
        let generationRateText = latestMetrics?.completionTokensPerSecond.map(Self.rateText) ?? "--"
        let durationText = latestMetrics?.responseDurationSeconds.map(Self.durationText) ?? "--"

        var fragments: [String] = []
        if isProcessing {
            fragments.append("working \(Self.spinnerFrames[spinnerIndex % Self.spinnerFrames.count])")
        }
        fragments.append(contentsOf: [
            "ctx \(tokenWindowText)",
            "pre \(prefillText)",
            "pro \(promptRateText) tok/s",
            "gen \(generationRateText) tok/s",
            "time \(durationText)"
        ])
        if let latestModelID {
            fragments.insert(Self.modelDisplayName(latestModelID), at: 0)
        }
        return fragments.joined(separator: " | ")
    }

    private static func modelDisplayName(_ modelID: String) -> String {
        modelID
            .split(separator: "/")
            .last
            .map(String.init) ?? modelID
    }

    private func mergedMetrics(
        current: DirectAgentGenerationMetrics?,
        update: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        guard let current else {
            return update
        }
        return DirectAgentGenerationMetrics(
            promptTokenCount: update.promptTokenCount ?? current.promptTokenCount,
            cachedPromptTokenCount: update.cachedPromptTokenCount ?? current.cachedPromptTokenCount,
            promptTokensPerSecond: update.promptTokensPerSecond ?? current.promptTokensPerSecond,
            completionTokenCount: update.completionTokenCount ?? current.completionTokenCount,
            completionTokensPerSecond: update.completionTokensPerSecond ?? current.completionTokensPerSecond,
            responseDurationSeconds: update.responseDurationSeconds ?? current.responseDurationSeconds,
            contextTokenCount: update.contextTokenCount ?? current.contextTokenCount
        )
    }

    private static func tokenWindowText(
        usedTokens: Int?,
        metricUsedTokens: Int?,
        maxTokens: Int?
    ) -> String {
        let resolvedUsedTokens = usedTokens ?? metricUsedTokens
        let usedText = resolvedUsedTokens.map(contextTokenCountText) ?? "--"
        guard let maxTokens, maxTokens > 0 else {
            return "\(usedText) / --"
        }
        return "\(usedText) / \(contextWindowLimitText(maxTokens))"
    }

    private static func contextWindowLimitText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_048_576 {
            return String(format: "%.1fm", Double(value) / 1_048_576)
        }
        if absoluteValue >= 1_024 {
            return String(format: "%.1fk", Double(value) / 1_024)
        }
        return "\(value)"
    }

    private static func contextTokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func tokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 10_000 {
            return "\(value / 1_000)k"
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func rateText(_ value: Double) -> String {
        guard value.isFinite else {
            return "--"
        }
        return String(format: "%.1f", value)
    }

    private static func durationText(_ value: Double) -> String {
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

    private static func fit(_ text: String, width: Int) -> String {
        guard width > 3, text.count > width else {
            return text
        }
        return String(text.prefix(width - 3)) + "..."
    }

    private static func padded(_ text: String, width: Int) -> String {
        guard text.count < width else {
            return text
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    private func inputPanelDisplayLineCountLocked(
        text: String,
        cursorIndex: Int
    ) -> Int {
        inputPanelDisplayRowsLocked(text: text, cursorIndex: cursorIndex).count
    }

    private func inputPanelDisplayRowsLocked(
        text: String,
        cursorIndex: Int
    ) -> [String] {
        Self.inputPanelDisplayRows(
            text: text,
            cursorIndex: cursorIndex,
            contentWidth: statusBoxContentWidthLocked(),
            maxRows: maximumInputPanelTextRowsLocked()
        )
    }

    private func inputPanelSuggestionRowsLocked(lines: [String]) -> [String] {
        let contentWidth = statusBoxContentWidthLocked()
        return lines.prefix(6).map { line in
            Self.padded(Self.fit(line, width: contentWidth), width: contentWidth)
        }
    }

    private func statusBoxHorizontalInsetLocked() -> Int {
        0
    }

    private func statusBoxStartColumnLocked() -> Int {
        statusBoxHorizontalInsetLocked() + 1
    }

    private func statusBoxWidthLocked() -> Int {
        max(20, columns - statusBoxHorizontalInsetLocked() * 2)
    }

    private func statusBoxContentWidthLocked() -> Int {
        max(1, statusBoxWidthLocked() - 4)
    }

    private func maximumInputPanelTextRowsLocked() -> Int {
        let suggestionLineCount = inputPanelState?.suggestionLines.count ?? 0
        guard row > 0 else {
            return 1
        }

        return max(
            1,
            row
                - Self.inputPanelChromeRows
                - suggestionLineCount
                - Self.attachedStatusRows
                - Self.minimumScrollableRows
        )
    }

    private static func inputPanelDisplayRows(
        text: String,
        cursorIndex: Int,
        contentWidth: Int,
        maxRows: Int
    ) -> [String] {
        let marker: Character = "▌"
        let promptPrefix = "> "
        let continuationPrefix = "  "
        let inputWidth = max(1, contentWidth - promptPrefix.count)
        var characters = Array(text)
        let boundedCursorIndex = min(max(0, cursorIndex), characters.count)
        characters.insert(marker, at: boundedCursorIndex)

        var logicalLines: [[Character]] = [[]]
        for character in characters {
            if character == "\n" {
                logicalLines.append([])
            } else {
                logicalLines[logicalLines.count - 1].append(character)
            }
        }

        var rows: [String] = []
        for (logicalLineIndex, logicalLine) in logicalLines.enumerated() {
            var remaining = logicalLine
            var isFirstVisualRow = true
            repeat {
                let chunkLength = min(inputWidth, remaining.count)
                let chunk = remaining.prefix(chunkLength)
                if chunkLength > 0 {
                    remaining.removeFirst(chunkLength)
                }
                let prefix: String
                if rows.isEmpty && logicalLineIndex == 0 && isFirstVisualRow {
                    prefix = promptPrefix
                } else {
                    prefix = continuationPrefix
                }
                rows.append(Self.padded(prefix + String(chunk), width: contentWidth))
                isFirstVisualRow = false
            } while !remaining.isEmpty
        }

        guard !rows.isEmpty else {
            return [Self.padded(promptPrefix + String(marker), width: contentWidth)]
        }
        return visibleInputRows(
            rows,
            maxRows: max(1, maxRows),
            marker: marker,
            contentWidth: contentWidth
        )
    }

    private static func visibleInputRows(
        _ rows: [String],
        maxRows: Int,
        marker: Character,
        contentWidth: Int
    ) -> [String] {
        guard rows.count > maxRows else {
            return rows
        }

        let cursorRowIndex = rows.firstIndex { $0.contains(marker) } ?? max(0, rows.count - 1)
        let windowStart = min(
            max(0, cursorRowIndex - maxRows / 2),
            max(0, rows.count - maxRows)
        )
        let windowEnd = min(rows.count, windowStart + maxRows)
        var visibleRows = Array(rows[windowStart..<windowEnd])

        if maxRows >= 3, windowStart > 0, !visibleRows.isEmpty, cursorRowIndex != windowStart {
            visibleRows[0] = Self.padded("  ... earlier", width: contentWidth)
        }
        if maxRows >= 3,
           windowEnd < rows.count,
           !visibleRows.isEmpty,
           cursorRowIndex != windowEnd - 1 {
            visibleRows[visibleRows.count - 1] = Self.padded("  ... later", width: contentWidth)
        }
        return visibleRows
    }

    private func startSpinnerTimerLocked() {
        guard isStarted, spinnerTimer == nil else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            self?.advanceSpinner()
        }
        spinnerTimer = timer
        timer.resume()
    }

    private func stopSpinnerTimerLocked() {
        spinnerTimer?.setEventHandler {}
        spinnerTimer?.cancel()
        spinnerTimer = nil
    }

    private func advanceSpinner() {
        lock.lock()
        defer { lock.unlock() }

        guard isStarted, isProcessing else {
            return
        }
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
        renderLocked()
    }

    private func startResizeSignalSourceLocked() {
        guard resizeSignalSource == nil else {
            return
        }
        signal(SIGWINCH, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGWINCH,
            queue: .global(qos: .userInteractive)
        )
        source.setEventHandler { [weak self] in
            self?.scheduleTerminalResize()
        }
        resizeSignalSource = source
        source.resume()
    }

    private func stopResizeSignalSourceLocked() {
        resizeSignalSource?.setEventHandler {}
        resizeSignalSource?.cancel()
        resizeSignalSource = nil
    }

    private func scheduleTerminalResize() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        resizeGeneration += 1
        let generation = resizeGeneration
        lock.unlock()

        DispatchQueue.global(qos: .userInteractive).asyncAfter(
            deadline: .now() + .milliseconds(80)
        ) { [weak self] in
            self?.handleTerminalResize(generation: generation)
        }
    }

    private func handleTerminalResize(generation: Int) {
        lock.lock()
        defer { lock.unlock() }

        guard isStarted, generation == resizeGeneration else {
            return
        }
        guard refreshTerminalGeometryLocked() else {
            return
        }
        renderLocked()
    }

    private static func currentTerminalGeometry(
        fileDescriptor: Int32
    ) -> (rows: Int, columns: Int)? {
        var size = winsize()
        if ioctl(fileDescriptor, TIOCGWINSZ, &size) == 0,
           size.ws_row > 0,
           size.ws_col > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }

        let environment = ProcessInfo.processInfo.environment
        guard let rows = positiveInt(environment["LINES"]),
              let columns = positiveInt(environment["COLUMNS"]) else {
            return defaultGeometryIfReasonable()
        }
        return (rows, columns)
    }

    private static func openControllingTerminal() -> FileHandle? {
        if AgentOutput.standardErrorIsTerminal {
            return AgentOutput.standardError
        }

        let terminalFileDescriptor = open("/dev/tty", O_WRONLY | O_NOCTTY)
        if terminalFileDescriptor >= 0 {
            return FileHandle(fileDescriptor: terminalFileDescriptor, closeOnDealloc: true)
        }

        return nil
    }

    private func writeLocked(_ text: String) {
        output?.writeString(text)
    }

    private static func positiveInt(_ rawValue: String?) -> Int? {
        guard let value = rawValue
            .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
              value > 0 else {
            return nil
        }
        return value
    }

    private static func defaultGeometryIfReasonable() -> (rows: Int, columns: Int)? {
        // Some pseudo-terminals support ANSI scrolling but do not report size
        // through ioctl. Keep a conservative default so the status line still
        // becomes persistent instead of degrading into regular log lines.
        (rows: 24, columns: 100)
    }
}
