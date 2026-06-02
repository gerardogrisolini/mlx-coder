//
//  TerminalSwiftMarkdownRenderer.swift
//  mlx-coder
//

import Foundation
import Markdown

struct TerminalSwiftMarkdownRenderer: MarkupVisitor {
    typealias Result = String

    private static let reset = "\u{1B}[0m"
    private static let bold = "\u{1B}[1m"
    private static let italic = "\u{1B}[3m"
    private static let strikethrough = "\u{1B}[9m"
    private static let dim = "\u{1B}[90m"
    private static let heading = "\u{1B}[1;38;5;81m"
    private static let code = "\u{1B}[38;5;222m"
    private static let bullet = "\u{1B}[38;5;214m"

    mutating func defaultVisit(_ markup: Markup) -> String {
        renderChildren(of: markup)
    }

    mutating func visitDocument(_ document: Document) -> String {
        renderChildren(of: document, separator: "\n")
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        renderChildren(of: paragraph)
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        "\(Self.heading)\(renderChildren(of: heading))\(Self.reset)"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        let body = renderChildren(of: blockQuote, separator: "\n")
        let quoted = body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "| \($0)" }
            .joined(separator: "\n")
        return "\(Self.dim)\(quoted)\(Self.reset)"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        var renderedItems: [String] = []
        for item in unorderedList.listItems {
            renderedItems.append(renderListItem(item, marker: "*"))
        }
        return renderedItems.joined(separator: "\n")
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        var number = Int(orderedList.startIndex)
        var renderedItems: [String] = []
        for item in orderedList.listItems {
            renderedItems.append(renderListItem(item, marker: "\(number)."))
            number += 1
        }
        return renderedItems.joined(separator: "\n")
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        renderChildren(of: listItem)
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let fence = codeBlock.language.map { "```\($0)" } ?? "```"
        return [
            "\(Self.dim)\(fence)\(Self.reset)",
            TerminalCodeBlockRenderer.renderBlock(
                codeBlock.code,
                language: codeBlock.language
            ),
            "\(Self.dim)```\(Self.reset)"
        ].joined(separator: "\n")
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "\(Self.dim)---\(Self.reset)"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "\(Self.code)\(inlineCode.code)\(Self.reset)"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "\(Self.bold)\(renderChildren(of: strong))\(Self.reset)"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "\(Self.italic)\(renderChildren(of: emphasis))\(Self.reset)"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "\(Self.strikethrough)\(renderChildren(of: strikethrough))\(Self.reset)"
    }

    mutating func visitLink(_ link: Link) -> String {
        let label = renderChildren(of: link)
        guard let destination = link.destination,
              destination != label else {
            return label
        }
        return "\(label) \(Self.dim)<\(destination)>\(Self.reset)"
    }

    mutating func visitImage(_ image: Image) -> String {
        let label = renderChildren(of: image)
        guard let source = image.source else {
            return label
        }
        let alt = label.isEmpty ? "image" : label
        return "\(alt) \(Self.dim)<\(source)>\(Self.reset)"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "\n"
    }

    mutating func visitText(_ text: Text) -> String {
        text.string
    }

    private mutating func renderChildren(
        of markup: Markup,
        separator: String = ""
    ) -> String {
        var rendered: [String] = []
        for child in markup.children {
            rendered.append(visit(child))
        }
        return rendered.joined(separator: separator)
    }

    private mutating func renderListItem(
        _ listItem: ListItem,
        marker: String
    ) -> String {
        let checkbox = listItem.checkbox.map {
            switch $0 {
            case .checked:
                return "[x] "
            case .unchecked:
                return "[ ] "
            }
        } ?? ""
        let content = renderChildren(of: listItem, separator: "\n")
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let renderedMarker = "\(Self.bullet)\(marker)\(Self.reset)"
        guard let firstLine = lines.first else {
            return "\(renderedMarker) \(checkbox)"
        }

        let continuationIndent = String(repeating: " ", count: marker.count + checkbox.count + 1)
        let first = "\(renderedMarker) \(checkbox)\(firstLine)"
        let rest = lines.dropFirst()
            .map { "\n\(continuationIndent)\($0)" }
            .joined()
        return first + rest
    }
}
