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

public final class StdioLineReader: @unchecked Sendable {
    private var buffer: [UInt8] = []

    public func readLine() -> String? {
        while true {
            if let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineBytes = Array(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                return String(decoding: trimmedCarriageReturn(from: lineBytes), as: UTF8.self)
            }

            let data = FileHandle.standardInput.availableData
            if data.isEmpty {
                guard !buffer.isEmpty else {
                    return nil
                }
                let lineBytes = buffer
                buffer.removeAll()
                return String(decoding: trimmedCarriageReturn(from: lineBytes), as: UTF8.self)
            }
            buffer.append(contentsOf: data)
        }
    }

    public func drainBufferedLines(waitMilliseconds: Int32 = 0) -> [String] {
        if waitMilliseconds > 0 {
            drainPendingInput(waitMilliseconds: waitMilliseconds)
        }

        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0a) {
            let lineBytes = Array(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            lines.append(String(decoding: trimmedCarriageReturn(from: lineBytes), as: UTF8.self))
        }
        if !buffer.isEmpty {
            let lineBytes = buffer
            buffer.removeAll()
            lines.append(String(decoding: trimmedCarriageReturn(from: lineBytes), as: UTF8.self))
        }
        return lines
    }

    private func drainPendingInput(waitMilliseconds: Int32) {
        var timeout = waitMilliseconds
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeout)
            guard pollResult > 0,
                  (descriptor.revents & Int16(POLLIN)) != 0 else {
                return
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                read(STDIN_FILENO, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard readCount > 0 else {
                return
            }
            buffer.append(contentsOf: bytes.prefix(readCount))
            timeout = 25
        }
    }

    private func trimmedCarriageReturn(from bytes: [UInt8]) -> [UInt8] {
        guard bytes.last == 0x0d else {
            return bytes
        }
        return Array(bytes.dropLast())
    }
}

public final class TerminalRawInput: @unchecked Sendable {
    private struct InputFileDescriptor {
        let fileDescriptor: Int32
        let shouldClose: Bool
        let label: String
        let canWrite: Bool
    }

    private var fileDescriptor: Int32
    private var shouldCloseFileDescriptor: Bool
    private var controlFileDescriptor: Int32
    private var shouldCloseControlFileDescriptor: Bool
    private var inputFileDescriptorLabel: String
    private var rawModeFailureDescription: String?
    private let lock = NSLock()
    private var originalAttributes: termios?
    private var didRequestEnhancedKeyboardProtocol = false

    public init() {
        if let inputFileDescriptor = Self.openPreferredInputFileDescriptor() {
            let controlFileDescriptor = Self.openTerminalControlFileDescriptor(
                inputFileDescriptor: inputFileDescriptor
            )

            self.fileDescriptor = inputFileDescriptor.fileDescriptor
            self.shouldCloseFileDescriptor = inputFileDescriptor.shouldClose
            self.controlFileDescriptor = controlFileDescriptor.fileDescriptor
            self.shouldCloseControlFileDescriptor = controlFileDescriptor.shouldClose
            self.inputFileDescriptorLabel = inputFileDescriptor.label
        } else {
            self.fileDescriptor = -1
            self.shouldCloseFileDescriptor = false
            self.controlFileDescriptor = -1
            self.shouldCloseControlFileDescriptor = false
            self.inputFileDescriptorLabel = "terminal"
            self.rawModeFailureDescription = Self.noForegroundTerminalDescription
        }
    }

    deinit {
        restoreRawMode()
        if shouldCloseControlFileDescriptor,
           controlFileDescriptor >= 0,
           controlFileDescriptor != fileDescriptor {
            close(controlFileDescriptor)
        }
        if shouldCloseFileDescriptor, fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    public static func supportsInteractiveInput() -> Bool {
        guard let inputFileDescriptor = openPreferredInputFileDescriptor() else {
            return false
        }
        if inputFileDescriptor.shouldClose {
            close(inputFileDescriptor.fileDescriptor)
        }
        return true
    }

    private static func openPreferredInputFileDescriptor() -> InputFileDescriptor? {
        if isTerminalDevice(fileDescriptor: STDIN_FILENO) {
            return InputFileDescriptor(
                fileDescriptor: STDIN_FILENO,
                shouldClose: false,
                label: "stdin",
                canWrite: true
            )
        }

        if let terminalFileDescriptor = openTerminalInput(
            path: "/dev/tty",
            label: "/dev/tty"
        ) {
            return terminalFileDescriptor
        }

        return nil
    }

    private static func openTerminalControlFileDescriptor(
        inputFileDescriptor: InputFileDescriptor
    ) -> (fileDescriptor: Int32, shouldClose: Bool) {
        if inputFileDescriptor.canWrite {
            return (inputFileDescriptor.fileDescriptor, false)
        }

        if let terminalPath = terminalPath(for: inputFileDescriptor.fileDescriptor),
           let terminalFileDescriptor = openTerminalOutput(path: terminalPath) {
            return terminalFileDescriptor
        }

        if let terminalFileDescriptor = openTerminalOutput(path: "/dev/tty") {
            return terminalFileDescriptor
        }

        if isTerminalDevice(fileDescriptor: STDERR_FILENO) {
            return (STDERR_FILENO, false)
        }

        if isTerminalDevice(fileDescriptor: STDOUT_FILENO) {
            return (STDOUT_FILENO, false)
        }

        return (-1, false)
    }

    private static func openTerminalInput(
        path: String,
        label: String
    ) -> InputFileDescriptor? {
        let attempts: [(flags: Int32, canWrite: Bool)] = [
            (O_RDWR | O_NOCTTY, true),
            (O_RDONLY | O_NOCTTY, false)
        ]

        for attempt in attempts {
            let terminalFileDescriptor = open(path, attempt.flags)
            guard terminalFileDescriptor >= 0 else {
                continue
            }
            guard isTerminalDevice(fileDescriptor: terminalFileDescriptor) else {
                close(terminalFileDescriptor)
                continue
            }
            return InputFileDescriptor(
                fileDescriptor: terminalFileDescriptor,
                shouldClose: true,
                label: label,
                canWrite: attempt.canWrite
            )
        }
        return nil
    }

    private static func openTerminalOutput(
        path: String
    ) -> (fileDescriptor: Int32, shouldClose: Bool)? {
        let terminalFileDescriptor = open(path, O_WRONLY | O_NOCTTY)
        guard terminalFileDescriptor >= 0 else {
            return nil
        }

        guard isTerminalDevice(fileDescriptor: terminalFileDescriptor) else {
            close(terminalFileDescriptor)
            return nil
        }
        return (terminalFileDescriptor, true)
    }

    private static func isTerminalDevice(fileDescriptor: Int32) -> Bool {
        guard fileDescriptor >= 0,
              isatty(fileDescriptor) == 1 else {
            return false
        }
        return true
    }

    private static func ensureForegroundTerminal(fileDescriptor: Int32) -> Bool {
        guard isTerminalDevice(fileDescriptor: fileDescriptor) else {
            return false
        }

        let foregroundProcessGroup = tcgetpgrp(fileDescriptor)
        guard foregroundProcessGroup >= 0 else {
            return false
        }

        let currentProcessGroup = getpgrp()
        guard foregroundProcessGroup != currentProcessGroup else {
            return true
        }

        guard withSIGTTOUIgnored({ tcsetpgrp(fileDescriptor, currentProcessGroup) == 0 }) else {
            return false
        }
        return tcgetpgrp(fileDescriptor) == currentProcessGroup
    }

    @discardableResult
    public func beginRawMode() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if originalAttributes != nil {
            return true
        }

        rawModeFailureDescription = nil

        guard fileDescriptor >= 0 else {
            rawModeFailureDescription = Self.noForegroundTerminalDescription
            return false
        }

        _ = Self.ensureForegroundTerminal(fileDescriptor: fileDescriptor)

        if activateRawModeLocked(fileDescriptor: fileDescriptor) {
            rawModeFailureDescription = nil
            return true
        }

        return false
    }

    private func activateRawModeLocked(fileDescriptor: Int32) -> Bool {
        var attributes = termios()
        guard tcgetattr(fileDescriptor, &attributes) == 0 else {
            rawModeFailureDescription = "\(inputFileDescriptorLabel): tcgetattr failed: \(Self.errnoDescription())"
            return false
        }

        var rawAttributes = Self.rawTerminalAttributes(from: attributes)
        let didSetAttributes = Self.withSIGTTOUIgnored {
            tcsetattr(fileDescriptor, TCSANOW, &rawAttributes) == 0
        }
        guard didSetAttributes else {
            rawModeFailureDescription = "\(inputFileDescriptorLabel): tcsetattr failed: \(Self.errnoDescription())"
            return false
        }

        originalAttributes = attributes
        requestEnhancedKeyboardProtocolLocked()
        return true
    }

    private static func terminalPath(for fileDescriptor: Int32) -> String? {
        guard isatty(fileDescriptor) == 1,
              let path = ttyname(fileDescriptor) else {
            return nil
        }
        let value = String(cString: path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func restoreRawMode() {
        lock.lock()
        defer { lock.unlock() }

        guard var attributes = originalAttributes else {
            return
        }
        restoreEnhancedKeyboardProtocolLocked()
        _ = Self.withSIGTTOUIgnored {
            tcsetattr(fileDescriptor, TCSANOW, &attributes)
        }
        originalAttributes = nil
    }

    private func closeInputFileDescriptorLocked() {
        if shouldCloseFileDescriptor, fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        shouldCloseFileDescriptor = false
    }

    private func closeControlFileDescriptorLocked() {
        if shouldCloseControlFileDescriptor,
           controlFileDescriptor >= 0,
           controlFileDescriptor != fileDescriptor {
            close(controlFileDescriptor)
        }
        shouldCloseControlFileDescriptor = false
    }

    private func requestEnhancedKeyboardProtocolLocked() {
        guard !didRequestEnhancedKeyboardProtocol else {
            return
        }
        writeToTerminal("\u{1B}[>1u\u{1B}[>4;2m")
        didRequestEnhancedKeyboardProtocol = true
    }

    private func restoreEnhancedKeyboardProtocolLocked() {
        guard didRequestEnhancedKeyboardProtocol else {
            return
        }
        writeToTerminal("\u{1B}[<u\u{1B}[>4;0m")
        didRequestEnhancedKeyboardProtocol = false
    }

    private static func rawTerminalAttributes(from attributes: termios) -> termios {
        var rawAttributes = attributes

        rawAttributes.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | IEXTEN)
        rawAttributes.c_iflag &= ~tcflag_t(BRKINT | ICRNL | IGNCR | INLCR | INPCK | ISTRIP | IXON)
        rawAttributes.c_cflag |= tcflag_t(CS8)
        withUnsafeMutableBytes(of: &rawAttributes.c_cc) { controlCharacters in
            let minimumByteCountIndex = Int(VMIN)
            let timeoutIndex = Int(VTIME)
            if controlCharacters.indices.contains(minimumByteCountIndex) {
                controlCharacters[minimumByteCountIndex] = 1
            }
            if controlCharacters.indices.contains(timeoutIndex) {
                controlCharacters[timeoutIndex] = 0
            }
        }
        return rawAttributes
    }

    private static func withSIGTTOUIgnored<T>(_ body: () -> T) -> T {
        let previousSIGTTOUHandler = signal(SIGTTOU, SIG_IGN)
        defer {
            signal(SIGTTOU, previousSIGTTOUHandler)
        }
        return body()
    }

    private static var noForegroundTerminalDescription: String {
        "no foreground controlling terminal"
    }

    private static func errnoDescription() -> String {
        String(cString: strerror(errno))
    }

    public func lastRawModeFailureDescription() -> String? {
        lock.lock()
        defer { lock.unlock() }

        return rawModeFailureDescription
    }

    private func writeToTerminal(_ text: String) {
        guard controlFileDescriptor >= 0 else {
            return
        }
        guard let data = text.data(using: .utf8) else {
            return
        }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            _ = Darwin.write(controlFileDescriptor, baseAddress, rawBuffer.count)
        }
    }

    public func withRawTerminal<T>(_ body: () -> T) -> T {
        guard beginRawMode() else {
            return body()
        }
        defer {
            restoreRawMode()
        }
        return body()
    }

    public func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        guard fileDescriptor >= 0 else {
            return nil
        }

        if let timeoutMilliseconds {
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeoutMilliseconds)
            guard pollResult > 0,
                  (descriptor.revents & Int16(POLLIN)) != 0 else {
                return nil
            }
        }

        var byte: UInt8 = 0
        let readCount = read(fileDescriptor, &byte, 1)
        guard readCount == 1 else {
            return nil
        }
        return byte
    }
}

public enum TerminalPromptInputEvent: Sendable {
    case submitted(String)
    case cancelRequested
    case toggleToolDetailsRequested
    case endOfInput
}

public struct TerminalCommandSuggestion: Sendable {
    public let command: String
    public let summary: String
    public let requiresArgument: Bool

    public init(
        command: String,
        summary: String,
        requiresArgument: Bool = false
    ) {
        self.command = command
        self.summary = summary
        self.requiresArgument = requiresArgument
    }
}

public final class TerminalInteractiveLineReader: @unchecked Sendable {
    private enum Key {
        case character(String)
        case enter
        case newline
        case tab
        case backspace
        case delete
        case left
        case right
        case up
        case down
        case home
        case end
        case clearBeforeCursor
        case clearAfterCursor
        case toggleToolDetails
        case endOfInput
        case cancel
        case unknown
    }

    private static let escapeSequenceInitialTimeout: Int32 = 120
    private static let escapeSequenceContinuationTimeout: Int32 = 60
    private static let escapeSequenceMaximumLength = 24

    private var history: [String] = []
    private var historyIndex: Int?
    private var draftBeforeHistory: [Character] = []
    private let rawInput = TerminalRawInput()
    private let panelLock = NSLock()
    private var panelTask: Task<Void, Never>?
    private var panelStatusBar: TerminalStatusBar?
    private var panelBuffer: [Character] = []
    private var panelCursorIndex = 0
    private var panelIsProcessing = false
    private var panelQueuedPromptCount = 0
    private var panelCommandSuggestions: [TerminalCommandSuggestion] = []
    private var panelCommandSuggestionIndex = 0

    public func readLine(prompt: String) -> String? {
        var buffer: [Character] = []
        var cursorIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()

        AgentOutput.standardError.writeString(prompt)

        return rawInput.withRawTerminal {
            while true {
                guard let key = readKey() else {
                    AgentOutput.standardError.writeString("\n")
                    return nil
                }

                switch key {
                case let .character(text):
                    let characters = Array(text)
                    guard !characters.isEmpty else {
                        continue
                    }
                    buffer.insert(contentsOf: characters, at: cursorIndex)
                    cursorIndex += characters.count
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .enter:
                    let line = String(buffer)
                    AgentOutput.standardError.writeString("\n")
                    recordHistory(line)
                    return line
                case .newline:
                    buffer.insert("\n", at: cursorIndex)
                    cursorIndex += 1
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .tab:
                    continue
                case .backspace:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    buffer.remove(at: cursorIndex - 1)
                    cursorIndex -= 1
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .delete:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    buffer.remove(at: cursorIndex)
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .left:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    cursorIndex -= 1
                    AgentOutput.standardError.writeString("\u{1B}[1D")
                case .right:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    cursorIndex += 1
                    AgentOutput.standardError.writeString("\u{1B}[1C")
                case .up:
                    guard let previous = previousHistory(currentBuffer: buffer) else {
                        continue
                    }
                    buffer = previous
                    cursorIndex = buffer.count
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .down:
                    guard let next = nextHistory() else {
                        continue
                    }
                    buffer = next
                    cursorIndex = buffer.count
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .home:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    AgentOutput.standardError.writeString("\u{1B}[\(cursorIndex)D")
                    cursorIndex = 0
                case .end:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    AgentOutput.standardError.writeString("\u{1B}[\(buffer.count - cursorIndex)C")
                    cursorIndex = buffer.count
                case .clearBeforeCursor:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    buffer.removeSubrange(0..<cursorIndex)
                    cursorIndex = 0
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .clearAfterCursor:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    buffer.removeSubrange(cursorIndex..<buffer.count)
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .toggleToolDetails:
                    continue
                case .endOfInput:
                    if buffer.isEmpty {
                        AgentOutput.standardError.writeString("\n")
                        return nil
                    }
                case .cancel:
                    continue
                case .unknown:
                    continue
                }
            }
        }
    }

    @discardableResult
    public func startPanelInput(
        statusBar: TerminalStatusBar,
        commandSuggestions: [TerminalCommandSuggestion] = [],
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) -> Bool {
        panelLock.lock()
        if panelTask != nil {
            panelLock.unlock()
            return true
        }
        panelStatusBar = statusBar
        panelBuffer.removeAll()
        panelCursorIndex = 0
        panelCommandSuggestions = commandSuggestions
        panelCommandSuggestionIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()
        guard rawInput.beginRawMode() else {
            if let failureDescription = rawInput.lastRawModeFailureDescription() {
                AgentOutput.standardError.writeString(
                    "[mlx-coder] Interactive prompt raw input failed: \(failureDescription)\n"
                )
            }
            panelStatusBar = nil
            panelLock.unlock()
            return false
        }
        panelLock.unlock()

        renderPanel()
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            self.runPanelInputLoop(statusBar: statusBar, onEvent: onEvent)
        }

        panelLock.lock()
        panelTask = task
        panelLock.unlock()
        return true
    }

    public func stopPanelInput(clearPanel: Bool = true) async {
        let stopState = takePanelTaskForStop()

        stopState.task?.cancel()
        await stopState.task?.value
        rawInput.restoreRawMode()
        if clearPanel {
            stopState.statusBar?.clearInputPanel()
        }
        finishPanelStop(clearPanel: clearPanel)
    }

    private func takePanelTaskForStop() -> (
        task: Task<Void, Never>?,
        statusBar: TerminalStatusBar?
    ) {
        panelLock.lock()
        defer { panelLock.unlock() }

        let state = (task: panelTask, statusBar: panelStatusBar)
        panelTask = nil
        return state
    }

    private func finishPanelStop(clearPanel: Bool) {
        panelLock.lock()
        defer { panelLock.unlock() }

        if clearPanel {
            panelStatusBar = nil
            panelBuffer.removeAll()
            panelCursorIndex = 0
            panelCommandSuggestions.removeAll()
            panelCommandSuggestionIndex = 0
        }
        historyIndex = nil
        draftBeforeHistory.removeAll()
    }

    public func setPanelProcessing(_ isProcessing: Bool) {
        panelLock.lock()
        panelIsProcessing = isProcessing
        panelLock.unlock()
        renderPanel()
    }

    public func setQueuedPromptCount(_ count: Int) {
        panelLock.lock()
        panelQueuedPromptCount = max(0, count)
        panelLock.unlock()
        renderPanel()
    }

    public func refreshPanel() {
        renderPanel()
    }

    private func runPanelInputLoop(
        statusBar _: TerminalStatusBar,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) {
        while !Task.isCancelled {
            guard let key = readKey(pollTimeoutMilliseconds: 100) else {
                continue
            }
            handlePanelKey(key, onEvent: onEvent)
        }
    }

    private func handlePanelKey(
        _ key: Key,
        onEvent: @escaping @Sendable (TerminalPromptInputEvent) -> Void
    ) {
        switch key {
        case let .character(text):
            let characters = Array(text)
            guard !characters.isEmpty else {
                return
            }
            panelLock.lock()
            panelBuffer.insert(contentsOf: characters, at: panelCursorIndex)
            panelCursorIndex += characters.count
            historyIndex = nil
            panelLock.unlock()
            renderPanel()
        case .enter:
            panelLock.lock()
            if let submission = acceptPanelCommandSuggestionLocked(
                submitCommandWithoutArguments: true
            ) {
                panelLock.unlock()
                if let submittedLine = submission.submittedLine {
                    recordHistory(submittedLine)
                    onEvent(.submitted(submittedLine))
                }
                renderPanel()
                return
            }

            let line = String(panelBuffer)
            panelBuffer.removeAll()
            panelCursorIndex = 0
            historyIndex = nil
            draftBeforeHistory.removeAll()
            panelLock.unlock()

            if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                recordHistory(line)
            }
            onEvent(.submitted(line))
            renderPanel()
        case .tab:
            panelLock.lock()
            let accepted = acceptPanelCommandSuggestionLocked(
                submitCommandWithoutArguments: false
            ) != nil
            panelLock.unlock()
            if accepted {
                renderPanel()
            }
        case .newline:
            panelLock.lock()
            panelBuffer.insert("\n", at: panelCursorIndex)
            panelCursorIndex += 1
            panelCommandSuggestionIndex = 0
            historyIndex = nil
            panelLock.unlock()
            renderPanel()
        case .backspace:
            panelLock.lock()
            guard panelCursorIndex > 0 else {
                panelLock.unlock()
                return
            }
            panelBuffer.remove(at: panelCursorIndex - 1)
            panelCursorIndex -= 1
            panelLock.unlock()
            renderPanel()
        case .delete:
            panelLock.lock()
            guard panelCursorIndex < panelBuffer.count else {
                panelLock.unlock()
                return
            }
            panelBuffer.remove(at: panelCursorIndex)
            panelLock.unlock()
            renderPanel()
        case .left:
            panelLock.lock()
            if panelCursorIndex > 0 {
                panelCursorIndex -= 1
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .right:
            panelLock.lock()
            if panelCursorIndex < panelBuffer.count {
                panelCursorIndex += 1
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .up:
            panelLock.lock()
            if hasActiveCommandSuggestionsLocked() {
                movePanelCommandSuggestionSelectionLocked(delta: -1)
            } else if let previous = previousHistory(currentBuffer: panelBuffer) {
                panelBuffer = previous
                panelCursorIndex = panelBuffer.count
            }
            panelLock.unlock()
            renderPanel()
        case .down:
            panelLock.lock()
            if hasActiveCommandSuggestionsLocked() {
                movePanelCommandSuggestionSelectionLocked(delta: 1)
            } else if let next = nextHistory() {
                panelBuffer = next
                panelCursorIndex = panelBuffer.count
            }
            panelLock.unlock()
            renderPanel()
        case .home:
            panelLock.lock()
            panelCursorIndex = 0
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .end:
            panelLock.lock()
            panelCursorIndex = panelBuffer.count
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .clearBeforeCursor:
            panelLock.lock()
            if panelCursorIndex > 0 {
                panelBuffer.removeSubrange(0..<panelCursorIndex)
                panelCursorIndex = 0
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .clearAfterCursor:
            panelLock.lock()
            if panelCursorIndex < panelBuffer.count {
                panelBuffer.removeSubrange(panelCursorIndex..<panelBuffer.count)
            }
            panelCommandSuggestionIndex = 0
            panelLock.unlock()
            renderPanel()
        case .toggleToolDetails:
            onEvent(.toggleToolDetailsRequested)
            renderPanel()
        case .cancel:
            panelLock.lock()
            let isProcessing = panelIsProcessing
            if !isProcessing {
                panelBuffer.removeAll()
                panelCursorIndex = 0
                panelCommandSuggestionIndex = 0
                historyIndex = nil
                draftBeforeHistory.removeAll()
            }
            panelLock.unlock()
            if isProcessing {
                onEvent(.cancelRequested)
            }
            renderPanel()
        case .endOfInput:
            panelLock.lock()
            let isEmpty = panelBuffer.isEmpty
            panelLock.unlock()
            if isEmpty {
                onEvent(.endOfInput)
            }
        case .unknown:
            return
        }
    }

    private func renderPanel() {
        panelLock.lock()
        let statusBar = panelStatusBar
        let text = String(panelBuffer)
        let cursorIndex = panelCursorIndex
        let modeText = panelModeTextLocked()
        let helpText = panelHelpTextLocked()
        let suggestionLines = panelCommandSuggestionLinesLocked()
        panelLock.unlock()

        statusBar?.updateInputPanel(
            text: text,
            cursorIndex: cursorIndex,
            modeText: modeText,
            helpText: helpText,
            suggestionLines: suggestionLines
        )
    }

    private func panelModeTextLocked() -> String {
        var modeText = panelIsProcessing ? "Next prompt" : "Prompt"
        if panelQueuedPromptCount > 0 {
            modeText += " · queued \(panelQueuedPromptCount)"
        }
        return modeText
    }

    private func panelHelpTextLocked() -> String {
        if hasActiveCommandSuggestionsLocked() {
            return "↑/↓ select · Tab complete · Enter choose"
        }
        return panelIsProcessing
            ? "Enter queue · Option+Enter newline · Ctrl+T tools · Esc stop"
            : "Enter send · Option+Enter newline · Ctrl+T tools · Esc clear"
    }

    private struct CommandSuggestionSelection {
        let submittedLine: String?
    }

    private func acceptPanelCommandSuggestionLocked(
        submitCommandWithoutArguments: Bool
    ) -> CommandSuggestionSelection? {
        guard let selectedSuggestion = selectedPanelCommandSuggestionLocked() else {
            return nil
        }

        let replacement = selectedSuggestion.requiresArgument
            ? "\(selectedSuggestion.command) "
            : selectedSuggestion.command
        panelBuffer = Array(replacement)
        panelCursorIndex = panelBuffer.count
        panelCommandSuggestionIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()

        guard submitCommandWithoutArguments,
              !selectedSuggestion.requiresArgument else {
            return CommandSuggestionSelection(submittedLine: nil)
        }

        let submittedLine = String(panelBuffer)
        panelBuffer.removeAll()
        panelCursorIndex = 0
        return CommandSuggestionSelection(submittedLine: submittedLine)
    }

    private func selectedPanelCommandSuggestionLocked() -> TerminalCommandSuggestion? {
        let suggestions = activeCommandSuggestionsLocked()
        guard !suggestions.isEmpty else {
            return nil
        }
        panelCommandSuggestionIndex = min(
            max(0, panelCommandSuggestionIndex),
            suggestions.count - 1
        )
        return suggestions[panelCommandSuggestionIndex]
    }

    private func hasActiveCommandSuggestionsLocked() -> Bool {
        !activeCommandSuggestionsLocked().isEmpty
    }

    private func movePanelCommandSuggestionSelectionLocked(delta: Int) {
        let suggestions = activeCommandSuggestionsLocked()
        guard !suggestions.isEmpty else {
            panelCommandSuggestionIndex = 0
            return
        }
        let count = suggestions.count
        panelCommandSuggestionIndex = (panelCommandSuggestionIndex + delta + count) % count
    }

    private func panelCommandSuggestionLinesLocked() -> [String] {
        let suggestions = activeCommandSuggestionsLocked()
        guard !suggestions.isEmpty else {
            panelCommandSuggestionIndex = 0
            return []
        }

        panelCommandSuggestionIndex = min(
            max(0, panelCommandSuggestionIndex),
            suggestions.count - 1
        )

        return suggestions.enumerated().map { index, suggestion in
            let marker = index == panelCommandSuggestionIndex ? "›" : " "
            return "\(marker) \(suggestion.command)  \(suggestion.summary)"
        }
    }

    private func activeCommandSuggestionsLocked() -> [TerminalCommandSuggestion] {
        guard let commandPrefix = Self.commandPrefixForSuggestions(
            text: String(panelBuffer),
            cursorIndex: panelCursorIndex
        ) else {
            return []
        }

        let normalizedPrefix = commandPrefix.lowercased()
        return panelCommandSuggestions.filter { suggestion in
            suggestion.command.lowercased().hasPrefix(normalizedPrefix)
        }
    }

    private static func commandPrefixForSuggestions(
        text: String,
        cursorIndex: Int
    ) -> String? {
        guard text.hasPrefix("/"), !text.contains("\n") else {
            return nil
        }

        let characters = Array(text)
        let boundedCursorIndex = min(max(0, cursorIndex), characters.count)
        let tokenEnd = characters.firstIndex { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
        } ?? characters.count
        guard boundedCursorIndex <= tokenEnd else {
            return nil
        }

        let prefix = String(characters.prefix(tokenEnd))
        return prefix.isEmpty ? nil : prefix
    }

    private func recordHistory(_ line: String) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              history.last != line else {
            return
        }
        history.append(line)
    }

    private func previousHistory(currentBuffer: [Character]) -> [Character]? {
        guard !history.isEmpty else {
            return nil
        }

        if let index = historyIndex {
            guard index > 0 else {
                return Array(history[0])
            }
            let previousIndex = index - 1
            historyIndex = previousIndex
            return Array(history[previousIndex])
        }

        draftBeforeHistory = currentBuffer
        let previousIndex = history.count - 1
        historyIndex = previousIndex
        return Array(history[previousIndex])
    }

    private func nextHistory() -> [Character]? {
        guard let index = historyIndex else {
            return nil
        }

        let nextIndex = index + 1
        guard nextIndex < history.count else {
            historyIndex = nil
            return draftBeforeHistory
        }

        historyIndex = nextIndex
        return Array(history[nextIndex])
    }

    private func redraw(prompt: String, buffer: [Character], cursorIndex: Int) {
        AgentOutput.standardError.writeString("\r\u{1B}[2K\(prompt)\(String(buffer))")
        let charactersAfterCursor = buffer.count - cursorIndex
        if charactersAfterCursor > 0 {
            AgentOutput.standardError.writeString("\u{1B}[\(charactersAfterCursor)D")
        }
    }

    private func readKey(pollTimeoutMilliseconds: Int32? = nil) -> Key? {
        guard let byte = readByte(timeoutMilliseconds: pollTimeoutMilliseconds) else {
            return nil
        }

        switch byte {
        case 0x04:
            return .endOfInput
        case 0x01:
            return .home
        case 0x05:
            return .end
        case 0x0B:
            return .clearAfterCursor
        case 0x15:
            return .clearBeforeCursor
        case 0x14:
            return .toggleToolDetails
        case 0x0A:
            return .enter
        case 0x0D:
            return .enter
        case 0x09:
            return .tab
        case 0x7F, 0x08:
            return .backspace
        case 0x1B:
            return readEscapeKey()
        default:
            return decodeCharacter(startingWith: byte).map(Key.character) ?? .unknown
        }
    }

    private func readEscapeKey() -> Key {
        guard let secondByte = readByte(timeoutMilliseconds: Self.escapeSequenceInitialTimeout) else {
            return .cancel
        }

        switch secondByte {
        case 0x0A, 0x0D:
            return .newline
        case 0x5B:
            return readCSIKey()
        case 0x4F:
            return readSS3Key()
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    private func readCSIKey() -> Key {
        var bytes: [UInt8] = []
        while bytes.count < Self.escapeSequenceMaximumLength {
            guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
                return .unknown
            }
            bytes.append(byte)
            if byte >= 0x40 && byte <= 0x7E {
                return keyFromCSI(bytes)
            }
        }

        drainPendingEscapeSequence()
        return .unknown
    }

    private func readSS3Key() -> Key {
        guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
            return .unknown
        }

        switch byte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        case 0x43:
            return .right
        case 0x44:
            return .left
        case 0x46:
            return .end
        case 0x48:
            return .home
        default:
            drainPendingEscapeSequence()
            return .unknown
        }
    }

    private func keyFromCSI(_ bytes: [UInt8]) -> Key {
        guard let finalByte = bytes.last else {
            return .unknown
        }

        switch finalByte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        case 0x43:
            return .right
        case 0x44:
            return .left
        case 0x46:
            return .end
        case 0x48:
            return .home
        case 0x7E:
            return tildeTerminatedKey(bytes)
        case 0x75:
            return csiUKey(bytes)
        default:
            return .unknown
        }
    }

    private func tildeTerminatedKey(_ bytes: [UInt8]) -> Key {
        guard let sequence = String(bytes: bytes.dropLast(), encoding: .utf8) else {
            return .unknown
        }
        let components = sequence.split(separator: ";").map(String.init)
        if let key = optionReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = optionReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1) {
            return key
        }
        let numericPrefix = components.first

        switch numericPrefix {
        case "1", "7":
            return .home
        case "3":
            return .delete
        case "4", "8":
            return .end
        default:
            return .unknown
        }
    }

    private func csiUKey(_ bytes: [UInt8]) -> Key {
        guard let sequence = String(bytes: bytes.dropLast(), encoding: .utf8) else {
            return .unknown
        }
        let components = sequence.split(separator: ";").map(String.init)
        if let key = optionReturnKey(components: components, keyCodeIndex: 0, modifierIndex: 1) {
            return key
        }
        if let key = optionReturnKey(components: components, keyCodeIndex: 2, modifierIndex: 1) {
            return key
        }
        return .unknown
    }

    private func optionReturnKey(
        components: [String],
        keyCodeIndex: Int,
        modifierIndex: Int
    ) -> Key? {
        guard components.indices.contains(keyCodeIndex),
              Self.isReturnKeyCode(Self.integerPrefix(in: components[keyCodeIndex])) else {
            return nil
        }
        guard components.indices.contains(modifierIndex),
              let modifier = Self.integerPrefix(in: components[modifierIndex]) else {
            return .enter
        }
        let modifierBits = modifier - 1
        return (modifierBits & 0b10) != 0 ? .newline : .enter
    }

    private static func isReturnKeyCode(_ keyCode: Int?) -> Bool {
        keyCode == 10 || keyCode == 13
    }

    private static func integerPrefix(in component: String) -> Int? {
        let prefix = component.split(separator: ":", maxSplits: 1).first
        return prefix.flatMap { Int($0) }
    }

    private func decodeCharacter(startingWith firstByte: UInt8) -> String? {
        guard firstByte >= 0x20 else {
            return nil
        }

        let byteCount = utf8ByteCount(startingWith: firstByte)
        guard byteCount > 0 else {
            return nil
        }
        guard byteCount > 1 else {
            return String(bytes: [firstByte], encoding: .utf8)
        }

        var bytes = [firstByte]
        while bytes.count < byteCount {
            guard let byte = readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) else {
                return nil
            }
            bytes.append(byte)
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private func utf8ByteCount(startingWith byte: UInt8) -> Int {
        if byte & 0b1000_0000 == 0 {
            return 1
        }
        if byte & 0b1110_0000 == 0b1100_0000 {
            return 2
        }
        if byte & 0b1111_0000 == 0b1110_0000 {
            return 3
        }
        if byte & 0b1111_1000 == 0b1111_0000 {
            return 4
        }
        return 0
    }

    private func drainPendingEscapeSequence() {
        while readByte(timeoutMilliseconds: Self.escapeSequenceContinuationTimeout) != nil {}
    }

    private func readByte(timeoutMilliseconds: Int32? = nil) -> UInt8? {
        rawInput.readByte(timeoutMilliseconds: timeoutMilliseconds)
    }
}
