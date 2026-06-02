//
//  TerminalCodeBlockRenderer.swift
//  mlx-coder
//

import Foundation

enum TerminalCodeBlockRenderer {
    private static let reset = "\u{1B}[0m"
    private static let keyword = "\u{1B}[38;5;141m"
    private static let type = "\u{1B}[38;5;81m"
    private static let string = "\u{1B}[38;5;114m"
    private static let comment = "\u{1B}[38;5;244m"
    private static let number = "\u{1B}[38;5;215m"
    private static let attribute = "\u{1B}[38;5;214m"
    private static let function = "\u{1B}[38;5;117m"
    private static let property = "\u{1B}[38;5;109m"

    private struct SyntaxProfile {
        var keywords: Set<String>
        var types: Set<String>
        var constants: Set<String>
        var lineComments: [String]
        var attributePrefixes: Set<Character>
        var directivePrefixes: Set<Character>
        var stringDelimiters: Set<Character>
        var allowsSwiftRawStrings: Bool

        static let generic = SyntaxProfile(
            keywords: [
                "and", "as", "async", "await", "break", "case", "catch", "class",
                "const", "continue", "def", "default", "do", "else", "enum",
                "except", "false", "for", "func", "function", "if", "import",
                "in", "let", "nil", "null", "return", "static", "struct",
                "switch", "throw", "true", "try", "var", "while", "yield"
            ],
            types: [],
            constants: ["false", "nil", "none", "null", "true"],
            lineComments: ["//", "#"],
            attributePrefixes: ["@"],
            directivePrefixes: [],
            stringDelimiters: ["\"", "'", "`"],
            allowsSwiftRawStrings: false
        )
    }

    static func renderBlock(_ code: String, language: String?) -> String {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .map { renderLine(String($0), language: language) }
            .joined(separator: "\n")
    }

    static func renderLine(_ line: String, language: String?) -> String {
        switch normalizedLanguage(language) {
        case "css":
            return renderCSSLine(line)
        case "html", "xml":
            return renderMarkupLine(line)
        case "json", "jsonc", "toml", "yaml":
            return renderDataLine(line, language: normalizedLanguage(language))
        default:
            return renderProfileLine(line, profile: profile(for: normalizedLanguage(language)))
        }
    }

    private static func normalizedLanguage(_ language: String?) -> String? {
        guard let language = language?.lowercased() else {
            return nil
        }
        switch language {
        case "bash", "sh", "shell", "zsh":
            return "shell"
        case "c++", "cc", "cpp", "cxx":
            return "cpp"
        case "c#", "csharp":
            return "csharp"
        case "dockerfile":
            return "docker"
        case "htm", "xhtml":
            return "html"
        case "javascript", "js", "jsx", "mjs":
            return "javascript"
        case "kt", "kts":
            return "kotlin"
        case "md", "markdown":
            return "markdown"
        case "objective-c", "objc":
            return "objc"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "swift", "swiftui":
            return "swift"
        case "ts", "tsx":
            return "typescript"
        case "yml":
            return "yaml"
        default:
            return language
        }
    }

    private static func renderProfileLine(
        _ line: String,
        profile: SyntaxProfile
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if matchingPrefix(
                in: line,
                at: index,
                prefixes: profile.lineComments
            ) != nil {
                rendered += "\(comment)\(line[index...])\(reset)"
                break
            }

            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(comment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: profile.stringDelimiters,
                allowsSwiftRawStrings: profile.allowsSwiftRawStrings
            ) {
                rendered += "\(string)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if profile.attributePrefixes.contains(line[index]) {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(attribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if profile.directivePrefixes.contains(line[index]),
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)].isLetter {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(keyword)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(number)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if containsToken(token, in: profile.keywords) {
                    rendered += "\(keyword)\(token)\(reset)"
                } else if containsToken(token, in: profile.types) {
                    rendered += "\(type)\(token)\(reset)"
                } else if containsToken(token, in: profile.constants) {
                    rendered += "\(number)\(token)\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(function)\(token)\(reset)"
                } else {
                    rendered += token
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    private static func renderDataLine(_ line: String, language: String?) -> String {
        let comments: [String] = {
            switch language {
            case "json":
                return []
            case "jsonc":
                return ["//"]
            default:
                return ["#"]
            }
        }()

        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if matchingPrefix(in: line, at: index, prefixes: comments) != nil {
                rendered += "\(comment)\(line[index...])\(reset)"
                break
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                let token = String(line[index..<stringEnd])
                if isObjectKey(in: line, after: stringEnd) {
                    rendered += "\(property)\(token)\(reset)"
                } else {
                    rendered += "\(string)\(token)\(reset)"
                }
                index = stringEnd
                continue
            }

            if line[index].isNumber || line[index] == "-" {
                let end = consumeNumber(in: line, from: index)
                if end > index {
                    rendered += "\(number)\(line[index..<end])\(reset)"
                    index = end
                    continue
                }
            }

            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if ["false", "null", "true"].contains(token.lowercased()) {
                    rendered += "\(number)\(token)\(reset)"
                } else if isObjectKey(in: line, after: end) {
                    rendered += "\(property)\(token)\(reset)"
                } else {
                    rendered += token
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    private static func renderMarkupLine(_ line: String) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if hasPrefix("<!--", in: line, at: index) {
                let end = endOfDelimitedSegment(
                    in: line,
                    from: index,
                    closing: "-->"
                )
                rendered += "\(comment)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index] == "<" {
                rendered.append("<")
                index = line.index(after: index)

                if index < line.endIndex, line[index] == "/" {
                    rendered.append("/")
                    index = line.index(after: index)
                }

                let tagEnd = consumeIdentifier(in: line, from: index)
                if tagEnd > index {
                    rendered += "\(keyword)\(line[index..<tagEnd])\(reset)"
                    index = tagEnd
                    continue
                }
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(string)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if isIdentifierStart(line[index]), isMarkupAttribute(in: line, after: index) {
                let end = consumeIdentifier(in: line, from: index)
                rendered += "\(attribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    private static func renderCSSLine(_ line: String) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(comment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(string)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if line[index] == "@" {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(attribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index] == "#",
               let end = cssColorEnd(in: line, from: index) {
                rendered += "\(number)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(number)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if isIdentifierStart(line[index]) {
                let end = consumeCSSIdentifier(in: line, from: index)
                if isObjectKey(in: line, after: end) {
                    rendered += "\(property)\(line[index..<end])\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(function)\(line[index..<end])\(reset)"
                } else {
                    rendered += "\(type)\(line[index..<end])\(reset)"
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    private static func profile(for language: String?) -> SyntaxProfile {
        switch language {
        case "swift":
            return SyntaxProfile(
                keywords: [
                    "actor", "any", "as", "associatedtype", "async", "await", "borrowing",
                    "break", "case", "catch", "class", "consuming", "continue", "default",
                    "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                    "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
                    "indirect", "init", "inout", "internal", "is", "isolated", "let", "nil",
                    "nonisolated", "open", "operator", "private", "protocol", "public",
                    "repeat", "rethrows", "return", "self", "some", "static", "struct",
                    "subscript", "super", "switch", "throw", "throws", "true", "try",
                    "typealias", "var", "where", "while"
                ],
                types: [
                    "Array", "Bool", "Character", "Data", "Date", "Dictionary", "Double",
                    "Error", "Float", "Int", "Int64", "Never", "Optional", "Result",
                    "Set", "String", "UInt", "URL", "Void"
                ],
                constants: ["false", "nil", "true"],
                lineComments: ["//"],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\""],
                allowsSwiftRawStrings: true
            )
        case "javascript", "typescript":
            return SyntaxProfile(
                keywords: [
                    "as", "async", "await", "break", "case", "catch", "class", "const",
                    "continue", "debugger", "default", "delete", "do", "else", "export",
                    "extends", "finally", "for", "from", "function", "if", "import",
                    "in", "instanceof", "interface", "let", "new", "of", "private",
                    "protected", "public", "return", "static", "super", "switch",
                    "throw", "try", "type", "typeof", "var", "void", "while", "yield"
                ],
                types: [
                    "Array", "Boolean", "Date", "Error", "Map", "Number", "Object",
                    "Promise", "Record", "Set", "String", "boolean", "never", "number",
                    "string", "unknown", "void"
                ],
                constants: ["false", "null", "true", "undefined"],
                lineComments: ["//"],
                attributePrefixes: ["@"],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'", "`"],
                allowsSwiftRawStrings: false
            )
        case "python":
            return SyntaxProfile(
                keywords: [
                    "False", "None", "True", "and", "as", "assert", "async", "await",
                    "break", "class", "continue", "def", "del", "elif", "else",
                    "except", "finally", "for", "from", "global", "if", "import",
                    "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                    "return", "try", "while", "with", "yield"
                ],
                types: ["bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple"],
                constants: ["False", "None", "True"],
                lineComments: ["#"],
                attributePrefixes: ["@"],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            )
        case "shell":
            return SyntaxProfile(
                keywords: [
                    "case", "do", "done", "elif", "else", "esac", "fi", "for",
                    "function", "if", "in", "select", "then", "until", "while"
                ],
                types: [],
                constants: ["false", "true"],
                lineComments: ["#"],
                attributePrefixes: [],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'", "`"],
                allowsSwiftRawStrings: false
            )
        case "rust":
            return SyntaxProfile(
                keywords: [
                    "as", "async", "await", "break", "const", "continue", "crate",
                    "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
                    "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                    "pub", "ref", "return", "self", "static", "struct", "super",
                    "trait", "true", "type", "unsafe", "use", "where", "while"
                ],
                types: [
                    "Box", "Option", "Result", "Self", "String", "Vec", "bool", "char",
                    "f32", "f64", "i32", "i64", "isize", "str", "u32", "u64", "usize"
                ],
                constants: ["false", "None", "Some", "true"],
                lineComments: ["//"],
                attributePrefixes: ["#"],
                directivePrefixes: [],
                stringDelimiters: ["\""],
                allowsSwiftRawStrings: false
            )
        case "go":
            return SyntaxProfile(
                keywords: [
                    "break", "case", "chan", "const", "continue", "default", "defer",
                    "else", "fallthrough", "for", "func", "go", "goto", "if",
                    "import", "interface", "map", "package", "range", "return",
                    "select", "struct", "switch", "type", "var"
                ],
                types: [
                    "any", "bool", "byte", "complex64", "complex128", "error", "float32",
                    "float64", "int", "int32", "int64", "rune", "string", "uint", "uint64"
                ],
                constants: ["false", "nil", "true"],
                lineComments: ["//"],
                attributePrefixes: [],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'", "`"],
                allowsSwiftRawStrings: false
            )
        case "c", "cpp", "objc":
            return SyntaxProfile(
                keywords: [
                    "auto", "break", "case", "catch", "class", "const", "constexpr",
                    "continue", "default", "delete", "do", "else", "enum", "extern",
                    "for", "friend", "goto", "if", "inline", "namespace", "new",
                    "operator", "private", "protected", "public", "return", "sizeof",
                    "static", "struct", "switch", "template", "this", "throw", "try",
                    "typedef", "typename", "union", "using", "virtual", "void", "while"
                ],
                types: [
                    "BOOL", "bool", "char", "double", "float", "int", "int32_t",
                    "int64_t", "long", "short", "size_t", "std", "string", "uint32_t",
                    "uint64_t"
                ],
                constants: ["false", "NULL", "nullptr", "true"],
                lineComments: ["//"],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            )
        case "java", "kotlin", "csharp":
            return SyntaxProfile(
                keywords: [
                    "abstract", "as", "break", "case", "catch", "class", "const",
                    "continue", "default", "do", "else", "enum", "extends", "final",
                    "finally", "for", "fun", "if", "implements", "import", "in",
                    "interface", "internal", "is", "new", "object", "override",
                    "package", "private", "protected", "public", "return", "sealed",
                    "static", "switch", "this", "throw", "throws", "try", "val",
                    "var", "void", "when", "while"
                ],
                types: [
                    "Boolean", "Char", "Double", "Exception", "Float", "Int",
                    "Integer", "List", "Long", "Map", "String", "boolean", "char",
                    "double", "float", "int", "long", "string"
                ],
                constants: ["false", "null", "true"],
                lineComments: ["//"],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            )
        case "php":
            return SyntaxProfile(
                keywords: [
                    "abstract", "and", "array", "as", "break", "case", "catch",
                    "class", "clone", "const", "continue", "declare", "default",
                    "do", "echo", "else", "elseif", "extends", "final", "finally",
                    "for", "foreach", "function", "global", "if", "implements",
                    "interface", "namespace", "new", "or", "private", "protected",
                    "public", "return", "static", "switch", "throw", "trait", "try",
                    "use", "var", "while", "xor"
                ],
                types: ["bool", "float", "int", "mixed", "string", "void"],
                constants: ["false", "null", "true"],
                lineComments: ["//", "#"],
                attributePrefixes: ["@"],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            )
        case "ruby":
            return SyntaxProfile(
                keywords: [
                    "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
                    "def", "defined", "do", "else", "elsif", "end", "ensure", "false",
                    "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                    "rescue", "retry", "return", "self", "super", "then", "true",
                    "undef", "unless", "until", "when", "while", "yield"
                ],
                types: ["Array", "Class", "Hash", "Integer", "Module", "String", "Symbol"],
                constants: ["false", "nil", "true"],
                lineComments: ["#"],
                attributePrefixes: ["@"],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'", "`"],
                allowsSwiftRawStrings: false
            )
        case "sql":
            return SyntaxProfile(
                keywords: [
                    "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE",
                    "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "FROM",
                    "GROUP", "HAVING", "IN", "INSERT", "INTO", "IS", "JOIN", "LEFT",
                    "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "RIGHT",
                    "SELECT", "SET", "TABLE", "THEN", "UPDATE", "VALUES", "WHEN",
                    "WHERE"
                ],
                types: ["BIGINT", "BOOLEAN", "DATE", "FLOAT", "INT", "INTEGER", "TEXT", "VARCHAR"],
                constants: ["FALSE", "NULL", "TRUE"],
                lineComments: ["--"],
                attributePrefixes: [],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            )
        case "docker":
            return SyntaxProfile(
                keywords: [
                    "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE",
                    "FROM", "HEALTHCHECK", "LABEL", "MAINTAINER", "ONBUILD", "RUN",
                    "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"
                ],
                types: [],
                constants: [],
                lineComments: ["#"],
                attributePrefixes: [],
                directivePrefixes: [],
                stringDelimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            )
        default:
            return .generic
        }
    }

    private static func matchingPrefix(
        in line: String,
        at index: String.Index,
        prefixes: [String]
    ) -> String? {
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) {
            if hasPrefix(prefix, in: line, at: index) {
                return prefix
            }
        }
        return nil
    }

    private static func hasPrefix(
        _ prefix: String,
        in line: String,
        at index: String.Index
    ) -> Bool {
        var cursor = index
        for character in prefix {
            guard cursor < line.endIndex, line[cursor] == character else {
                return false
            }
            cursor = line.index(after: cursor)
        }
        return true
    }

    private static func blockCommentEnd(
        in line: String,
        at index: String.Index
    ) -> String.Index? {
        guard hasPrefix("/*", in: line, at: index) else {
            return nil
        }
        return endOfDelimitedSegment(in: line, from: index, closing: "*/")
    }

    private static func endOfDelimitedSegment(
        in line: String,
        from start: String.Index,
        closing: String
    ) -> String.Index {
        var cursor = start
        while cursor < line.endIndex {
            if hasPrefix(closing, in: line, at: cursor) {
                var end = cursor
                for _ in closing {
                    end = line.index(after: end)
                }
                return end
            }
            cursor = line.index(after: cursor)
        }
        return line.endIndex
    }

    private static func stringEnd(
        in line: String,
        at index: String.Index,
        delimiters: Set<Character>,
        allowsSwiftRawStrings: Bool
    ) -> String.Index? {
        var hashCount = 0
        var quoteIndex = index
        while allowsSwiftRawStrings,
              quoteIndex < line.endIndex,
              line[quoteIndex] == "#" {
            hashCount += 1
            quoteIndex = line.index(after: quoteIndex)
        }

        guard quoteIndex < line.endIndex,
              delimiters.contains(line[quoteIndex]) else {
            return nil
        }

        let delimiter = line[quoteIndex]
        var cursor = line.index(after: quoteIndex)
        while cursor < line.endIndex {
            if hashCount == 0,
               line[cursor] == "\\" {
                cursor = line.index(after: cursor)
                if cursor < line.endIndex {
                    cursor = line.index(after: cursor)
                }
                continue
            }

            if line[cursor] == delimiter,
               stringClosingHashesMatch(
                in: line,
                afterQuoteAt: cursor,
                hashCount: hashCount
               ) {
                var end = line.index(after: cursor)
                for _ in 0..<hashCount {
                    end = line.index(after: end)
                }
                return end
            }

            cursor = line.index(after: cursor)
        }

        return line.endIndex
    }

    private static func stringClosingHashesMatch(
        in line: String,
        afterQuoteAt quoteIndex: String.Index,
        hashCount: Int
    ) -> Bool {
        var cursor = line.index(after: quoteIndex)
        for _ in 0..<hashCount {
            guard cursor < line.endIndex, line[cursor] == "#" else {
                return false
            }
            cursor = line.index(after: cursor)
        }
        return true
    }

    private static func consumeNumber(
        in line: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        if cursor < line.endIndex, line[cursor] == "-" {
            cursor = line.index(after: cursor)
        }
        guard cursor < line.endIndex,
              line[cursor].isNumber || line[cursor] == "." else {
            return start
        }
        while cursor < line.endIndex {
            let character = line[cursor]
            guard character.isNumber
                || character.isLetter
                || character == "."
                || character == "_"
            else {
                break
            }
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private static func consumeCSSIdentifier(
        in line: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < line.endIndex {
            let character = line[cursor]
            guard isIdentifierPart(character)
                || character == "-"
            else {
                break
            }
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private static func cssColorEnd(
        in line: String,
        from start: String.Index
    ) -> String.Index? {
        var cursor = line.index(after: start)
        var count = 0
        while cursor < line.endIndex,
              isHexDigit(line[cursor]),
              count < 8 {
            count += 1
            cursor = line.index(after: cursor)
        }
        return [3, 4, 6, 8].contains(count) ? cursor : nil
    }

    private static func consumeIdentifier(
        in line: String,
        from start: String.Index
    ) -> String.Index {
        var cursor = start
        while cursor < line.endIndex, isIdentifierPart(line[cursor]) {
            cursor = line.index(after: cursor)
        }
        return cursor
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }

    private static func isHexDigit(_ character: Character) -> Bool {
        switch character {
        case "a", "b", "c", "d", "e", "f",
             "A", "B", "C", "D", "E", "F":
            return true
        default:
            return character.isNumber
        }
    }

    private static func containsToken(
        _ token: String,
        in tokens: Set<String>
    ) -> Bool {
        tokens.contains(token)
            || tokens.contains(token.lowercased())
            || tokens.contains(token.uppercased())
    }

    private static func isObjectKey(
        in line: String,
        after end: String.Index
    ) -> Bool {
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && (line[cursor] == ":" || line[cursor] == "=")
    }

    private static func isMarkupAttribute(
        in line: String,
        after start: String.Index
    ) -> Bool {
        let end = consumeIdentifier(in: line, from: start)
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && line[cursor] == "="
    }

    private static func isFunctionCall(
        in line: String,
        after end: String.Index
    ) -> Bool {
        var cursor = end
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        return cursor < line.endIndex && line[cursor] == "("
    }
}
