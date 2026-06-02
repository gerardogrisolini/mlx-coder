//
//  TerminalMarkdownStreamFormatter.swift
//  mlx-coder
//

import Foundation
import Markdown

public struct TerminalMarkdownStreamFormatter {
    private static let reset = "\u{1B}[0m"
    private static let dim = "\u{1B}[90m"
    private static let code = "\u{1B}[38;5;222m"
    private static let maxBufferedLineLength = 240

    private let isEnabled: Bool
    private var pendingLine = ""
    private var isInCodeFence = false
    private var codeFenceLanguage: String?

    public init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    public mutating func consume(_ text: String) -> String {
        guard isEnabled else {
            return text
        }

        pendingLine += text
        var rendered = ""

        while let newlineIndex = pendingLine.firstIndex(of: "\n") {
            let line = String(pendingLine[..<newlineIndex])
            rendered += renderCompleteLine(line, appendsNewline: true)
            pendingLine.removeSubrange(pendingLine.startIndex...newlineIndex)
        }

        if pendingLine.count > Self.maxBufferedLineLength {
            rendered += renderCompleteLine(pendingLine, appendsNewline: false)
            pendingLine = ""
        }

        return rendered
    }

    public mutating func finish() -> String {
        guard isEnabled else {
            return ""
        }
        defer {
            isInCodeFence = false
            codeFenceLanguage = nil
        }
        guard !pendingLine.isEmpty else {
            return ""
        }
        defer {
            pendingLine = ""
        }
        return renderCompleteLine(pendingLine, appendsNewline: false)
    }

    private mutating func renderCompleteLine(
        _ line: String,
        appendsNewline: Bool
    ) -> String {
        let newline = appendsNewline ? "\n" : ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            if isInCodeFence {
                isInCodeFence = false
                codeFenceLanguage = nil
            } else {
                isInCodeFence = true
                codeFenceLanguage = codeFenceLanguage(from: trimmed)
            }
            return "\(Self.dim)\(line)\(Self.reset)\(newline)"
        }

        if isInCodeFence {
            return "\(TerminalCodeBlockRenderer.renderLine(line, language: codeFenceLanguage))\(newline)"
        }

        let parsed = leadingIndent(in: line)
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: parsed.body)
        return "\(parsed.indent)\(renderer.visit(document))\(newline)"
    }

    private func leadingIndent(in line: String) -> (indent: String, body: String) {
        let bodyStart = line.firstIndex { !$0.isWhitespace } ?? line.endIndex
        return (
            String(line[..<bodyStart]),
            String(line[bodyStart...])
        )
    }

    private func codeFenceLanguage(from line: String) -> String? {
        let info = String(line.dropFirst(3))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let language = info.split(whereSeparator: { $0.isWhitespace }).first else {
            return nil
        }
        return String(language).lowercased()
    }
}
