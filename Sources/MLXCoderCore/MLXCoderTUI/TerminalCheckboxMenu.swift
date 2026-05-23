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

public struct TerminalCheckboxMenuItem<Value: Hashable> {
    public let value: Value
    public let title: String
    public let detail: String?
    public let groupTitle: String?

    public init(
        value: Value,
        title: String,
        detail: String?,
        groupTitle: String? = nil
    ) {
        self.value = value
        self.title = title
        self.detail = detail
        self.groupTitle = groupTitle
    }
}

public enum TerminalCheckboxMenu {
    private struct RenderedFrame {
        let row: Int
        let height: Int
    }

    private struct RenderedMenuLine {
        let text: String
        let itemIndex: Int?
    }

    private enum Key {
        case up
        case down
        case toggle
        case submit
        case cancel
        case selectAll
        case selectNone
        case unknown
    }

    private static let escapeSequenceInitialTimeout: Int32 = 120
    private static let escapeSequenceContinuationTimeout: Int32 = 60
    private static let escapeSequenceMaximumLength = 24

    public static func select<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        reservedBottomRows: Int = 0
    ) -> Set<Value>? {
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("\(title)\nNo selectable items.\n")
            return initialSelection
        }

        var selectedValues = initialSelection
        var focusedIndex = 0
        var renderedFrame: RenderedFrame?

        AgentOutput.standardError.writeString("\u{1B}[?25l")
        defer {
            AgentOutput.standardError.writeString("\u{1B}[?25h")
        }

        let rawInput = TerminalRawInput()
        return rawInput.withRawTerminal {
            while true {
                clear(frame: renderedFrame)
                renderedFrame = render(
                    title: title,
                    items: items,
                    selectedValues: selectedValues,
                    focusedIndex: focusedIndex,
                    reservedBottomRows: reservedBottomRows
                )

                guard let key = readKey(rawInput: rawInput) else {
                    clear(frame: renderedFrame)
                    return nil
                }

                switch key {
                case .up:
                    focusedIndex = max(0, focusedIndex - 1)
                case .down:
                    focusedIndex = min(items.count - 1, focusedIndex + 1)
                case .toggle:
                    let value = items[focusedIndex].value
                    if selectedValues.contains(value) {
                        selectedValues.remove(value)
                    } else {
                        selectedValues.insert(value)
                    }
                case .selectAll:
                    selectedValues = Set(items.map(\.value))
                case .selectNone:
                    selectedValues.removeAll()
                case .submit:
                    clear(frame: renderedFrame)
                    return selectedValues
                case .cancel:
                    clear(frame: renderedFrame)
                    return nil
                case .unknown:
                    continue
                }
            }
        }
    }

    public static func selectOne<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        reservedBottomRows: Int = 0
    ) -> Value? {
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("\(title)\nNo selectable items.\n")
            return nil
        }

        var focusedIndex = items.firstIndex { item in
            item.value == initialSelection
        } ?? 0
        var selectedValue = initialSelection
        var renderedFrame: RenderedFrame?

        AgentOutput.standardError.writeString("\u{1B}[?25l")
        defer {
            AgentOutput.standardError.writeString("\u{1B}[?25h")
        }

        let rawInput = TerminalRawInput()
        return rawInput.withRawTerminal {
            while true {
                clear(frame: renderedFrame)
                renderedFrame = renderSingle(
                    title: title,
                    items: items,
                    selectedValue: selectedValue,
                    focusedIndex: focusedIndex,
                    reservedBottomRows: reservedBottomRows
                )

                guard let key = readKey(rawInput: rawInput) else {
                    clear(frame: renderedFrame)
                    return nil
                }

                switch key {
                case .up:
                    focusedIndex = max(0, focusedIndex - 1)
                    selectedValue = items[focusedIndex].value
                case .down:
                    focusedIndex = min(items.count - 1, focusedIndex + 1)
                    selectedValue = items[focusedIndex].value
                case .toggle, .submit:
                    clear(frame: renderedFrame)
                    return items[focusedIndex].value
                case .cancel:
                    clear(frame: renderedFrame)
                    return nil
                case .selectAll, .selectNone, .unknown:
                    continue
                }
            }
        }
    }

    private static func render<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selectedValues: Set<Value>,
        focusedIndex: Int,
        reservedBottomRows: Int
    ) -> RenderedFrame {
        let itemLines = groupedItemLines(items: items) { offset, item in
            let focus = offset == focusedIndex ? ">" : " "
            let checkbox = selectedValues.contains(item.value) ? "[x]" : "[ ]"
            return "\(focus) \(checkbox) \(item.title)\(detailSuffix(for: item))"
        }

        return renderFrame(
            title: title,
            help: "↑/↓ move · Space toggle · A all · N none · Enter confirm · Esc/Q cancel",
            itemLines: itemLines,
            focusedIndex: focusedIndex,
            reservedBottomRows: reservedBottomRows
        )
    }

    private static func renderSingle<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selectedValue: Value?,
        focusedIndex: Int,
        reservedBottomRows: Int
    ) -> RenderedFrame {
        let itemLines = groupedItemLines(items: items) { offset, item in
            let focus = offset == focusedIndex ? ">" : " "
            let marker = item.value == selectedValue ? "(x)" : "( )"
            return "\(focus) \(marker) \(item.title)\(detailSuffix(for: item))"
        }

        return renderFrame(
            title: title,
            help: "↑/↓ move · Enter select · Esc/Q cancel",
            itemLines: itemLines,
            focusedIndex: focusedIndex,
            reservedBottomRows: reservedBottomRows
        )
    }

    private static func groupedItemLines<Value: Hashable>(
        items: [TerminalCheckboxMenuItem<Value>],
        itemLine: (Int, TerminalCheckboxMenuItem<Value>) -> String
    ) -> [RenderedMenuLine] {
        var lines: [RenderedMenuLine] = []
        var currentGroupTitle: String?
        for (offset, item) in items.enumerated() {
            let groupTitle = normalizedGroupTitle(item.groupTitle)
            if groupTitle != currentGroupTitle {
                if !lines.isEmpty {
                    lines.append(RenderedMenuLine(text: "", itemIndex: nil))
                }
                if let groupTitle {
                    lines.append(RenderedMenuLine(text: groupTitle, itemIndex: nil))
                }
                currentGroupTitle = groupTitle
            }
            lines.append(RenderedMenuLine(text: itemLine(offset, item), itemIndex: offset))
        }

        return lines
    }

    private static func renderFrame(
        title: String,
        help: String,
        itemLines: [RenderedMenuLine],
        focusedIndex: Int,
        reservedBottomRows: Int
    ) -> RenderedFrame {
        let geometry = terminalGeometry()
        let availableRows = max(3, geometry.rows - max(0, reservedBottomRows))
        let fixedLines = [
            title,
            help,
            ""
        ]
        let contentCapacity = max(1, availableRows - 2)
        let itemCapacity = max(0, contentCapacity - fixedLines.count)
        let visibleItemLines = visibleItemLines(
            itemLines,
            focusedIndex: focusedIndex,
            capacity: itemCapacity
        )
        let lines = Array((fixedLines + visibleItemLines).prefix(contentCapacity))
        let requestedWidth = min(
            geometry.columns,
            max(48, min(120, longestLineLength(in: lines) + 4))
        )
        let boxWidth = max(20, requestedWidth)
        let contentWidth = max(1, boxWidth - 4)
        let renderedLines = lines.map { padded(fitLine($0, width: contentWidth), width: contentWidth) }
        let frameHeight = renderedLines.count + 2
        let startRow = max(1, availableRows - frameHeight + 1)
        let borderColor = "\u{1B}[38;5;208m"
        let resetColor = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))

        writeLine(
            row: startRow,
            text: "\(borderColor)╭\(horizontalRule)╮\(resetColor)"
        )
        for (offset, line) in renderedLines.enumerated() {
            writeLine(
                row: startRow + offset + 1,
                text: "\(borderColor)│\(resetColor) \(line) \(borderColor)│\(resetColor)"
            )
        }
        writeLine(
            row: startRow + frameHeight - 1,
            text: "\(borderColor)╰\(horizontalRule)╯\(resetColor)"
        )
        return RenderedFrame(row: startRow, height: frameHeight)
    }

    private static func visibleItemLines(
        _ itemLines: [RenderedMenuLine],
        focusedIndex: Int,
        capacity: Int
    ) -> [String] {
        guard capacity > 0 else {
            return []
        }
        guard itemLines.count > capacity else {
            return itemLines.map(\.text)
        }

        let focusedLineIndex = itemLines.firstIndex { line in
            line.itemIndex == focusedIndex
        } ?? 0
        let windowStart = min(
            max(0, focusedLineIndex - capacity / 2),
            max(0, itemLines.count - capacity)
        )
        let windowEnd = min(itemLines.count, windowStart + capacity)
        var visibleLines = itemLines[windowStart..<windowEnd].map(\.text)
        let canShowOverflowIndicators = capacity >= 3
        if canShowOverflowIndicators, windowStart > 0, !visibleLines.isEmpty {
            visibleLines[0] = "↑ more"
        }
        if canShowOverflowIndicators, windowEnd < itemLines.count, !visibleLines.isEmpty {
            visibleLines[visibleLines.count - 1] = "↓ more"
        }
        return visibleLines
    }

    private static func detailSuffix<Value: Hashable>(
        for item: TerminalCheckboxMenuItem<Value>
    ) -> String {
        guard let detail = item.detail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !detail.isEmpty else {
            return ""
        }
        return " - \(detail)"
    }

    private static func normalizedGroupTitle(_ value: String?) -> String? {
        guard let title = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return nil
        }
        return title
    }

    private static func terminalGeometry() -> (rows: Int, columns: Int) {
        var size = winsize()
        if ioctl(AgentOutput.standardError.fileDescriptor, TIOCGWINSZ, &size) == 0,
           size.ws_row > 0,
           size.ws_col > 0 {
            return (Int(size.ws_row), Int(size.ws_col))
        }

        let environment = ProcessInfo.processInfo.environment
        if let rawRows = environment["LINES"],
           let rows = Int(rawRows),
           rows > 0,
           let rawColumns = environment["COLUMNS"],
           let columns = Int(rawColumns),
           columns > 0 {
            return (rows, columns)
        }

        return (24, 100)
    }

    private static func longestLineLength(in lines: [String]) -> Int {
        lines.map(\.count).max() ?? 0
    }

    private static func fitLine(_ text: String, width: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard width > 3, singleLine.count > width else {
            return singleLine
        }
        return String(singleLine.prefix(width - 3)) + "..."
    }

    private static func padded(_ text: String, width: Int) -> String {
        guard text.count < width else {
            return text
        }
        return text + String(repeating: " ", count: width - text.count)
    }

    private static func clear(frame: RenderedFrame?) {
        guard let frame else {
            return
        }
        for row in frame.row..<(frame.row + frame.height) {
            writeLine(row: row, text: "")
        }
        AgentOutput.standardError.writeString("\u{1B}[\(frame.row);1H")
    }

    private static func writeLine(row: Int, text: String) {
        AgentOutput.standardError.writeString("\u{1B}[\(row);1H\u{1B}[2K\(text)")
    }

    private static func readKey(rawInput: TerminalRawInput) -> Key? {
        guard let byte = rawInput.readByte() else {
            return nil
        }

        switch byte {
        case 0x0A, 0x0D:
            return .submit
        case 0x20:
            return .toggle
        case 0x1B:
            return readEscapeKey(rawInput: rawInput)
        case 0x61, 0x41:
            return .selectAll
        case 0x6E, 0x4E:
            return .selectNone
        case 0x71, 0x51:
            return .cancel
        case 0x6A:
            return .down
        case 0x6B:
            return .up
        default:
            return .unknown
        }
    }

    private static func readEscapeKey(rawInput: TerminalRawInput) -> Key {
        guard let secondByte = rawInput.readByte(timeoutMilliseconds: escapeSequenceInitialTimeout) else {
            return .cancel
        }

        switch secondByte {
        case 0x5B:
            return readCSIKey(rawInput: rawInput)
        case 0x4F:
            return readSS3Key(rawInput: rawInput)
        default:
            drainPendingEscapeSequence(rawInput: rawInput)
            return .unknown
        }
    }

    private static func readCSIKey(rawInput: TerminalRawInput) -> Key {
        var bytes: [UInt8] = []
        while bytes.count < escapeSequenceMaximumLength {
            guard let byte = rawInput.readByte(timeoutMilliseconds: escapeSequenceContinuationTimeout) else {
                return .unknown
            }
            bytes.append(byte)
            if byte >= 0x40 && byte <= 0x7E {
                return keyFromCSI(bytes)
            }
        }

        drainPendingEscapeSequence(rawInput: rawInput)
        return .unknown
    }

    private static func readSS3Key(rawInput: TerminalRawInput) -> Key {
        guard let byte = rawInput.readByte(timeoutMilliseconds: escapeSequenceContinuationTimeout) else {
            return .unknown
        }

        switch byte {
        case 0x41:
            return .up
        case 0x42:
            return .down
        default:
            drainPendingEscapeSequence(rawInput: rawInput)
            return .unknown
        }
    }

    private static func keyFromCSI(_ bytes: [UInt8]) -> Key {
        switch bytes.last {
        case 0x41:
            return .up
        case 0x42:
            return .down
        default:
            return .unknown
        }
    }

    private static func drainPendingEscapeSequence(rawInput: TerminalRawInput) {
        while rawInput.readByte(timeoutMilliseconds: escapeSequenceContinuationTimeout) != nil {}
    }
}
