import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import MLXFeatureKit

struct LocalPwdTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {}

    static let name = "local.pwd"
    static let description = "Returns the current working directory used by local tools."
    static let inputSchema = #"{"type":"object","properties":{}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        context.workingDirectory.path
    }
}

struct LocalListDirectoryTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let includeHidden: Bool?
    }

    static let name = "local.ls"
    static let description = "Lists files and directories. Paths may be absolute or relative to the working directory."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"includeHidden":{"type":"boolean"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        try LocalToolsSupport.listDirectory(
            context.resolvePath(input.path ?? "."),
            includeHidden: input.includeHidden ?? false
        )
    }
}

struct LocalReadFileTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let offset: Int?
        let limit: Int?
    }

    static let name = "local.readFile"
    static let description = "Reads a UTF-8 text file with line numbers. Use offset and limit for focused reads."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        try LocalToolsSupport.readFile(
            LocalToolsSupport.requiredPath(input.path, input.file_path, context: context),
            offset: input.offset,
            limit: input.limit
        )
    }
}

struct SearchGlobTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let pattern: String?
        let path: String?
        let maxResults: Int?
        let max_results: Int?
    }

    static let name = "search.glob"
    static let description = "Finds files under a local path. Pass pattern for a glob such as **/*.swift; omit pattern to list files recursively."
    static let inputSchema = #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        try LocalToolsSupport.glob(input: input, context: context)
    }
}

struct SearchGrepTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let pattern: String?
        let path: String?
        let maxResults: Int?
        let max_results: Int?
    }

    static let name = "search.grep"
    static let description = "Searches text with grep from a local path."
    static let inputSchema = #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}},"required":["pattern"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        guard let pattern = input.pattern?.nilIfBlank else {
            throw LocalToolsFeatureError.missingArgument("pattern")
        }
        let path = context.resolvePath(input.path ?? ".")
        let maxResults = max(1, input.maxResults ?? input.max_results ?? 200)
        var processArguments = ["-E", "-R", "-n", "-I"]
        if maxResults < 10000 {
            processArguments.append(contentsOf: ["-m", "\(maxResults)"])
        }
        processArguments.append(pattern)
        processArguments.append(path.path)
        let result = try await MLXFeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/grep"),
            arguments: processArguments,
            workingDirectory: context.workingDirectory,
            environment: context.environment,
            timeout: 60
        )
        if result.exitCode == 1,
           result.stdout.isEmpty,
           result.stderr.isEmpty {
            return "No matches found."
        }
        return LocalToolsSupport.renderProcessResult(result)
            .components(separatedBy: .newlines)
            .prefix(maxResults)
            .joined(separator: "\n")
    }
}

struct TextHeadTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let lines: Int?
    }

    static let name = "text.head"
    static let description = "Reads the first lines of a local text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let lineCount = max(input.lines ?? 20, 1)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
            .prefix(lineCount)
        guard !lines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        return (["File: \(path.path)"] + lines.enumerated().map { index, line in
            "\(index + 1)\t\(line)"
        }).joined(separator: "\n")
    }
}

struct TextTailTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let lines: Int?
    }

    static let name = "text.tail"
    static let description = "Reads the last lines of a local text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"lines":{"type":"number"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let lineCount = max(input.lines ?? 20, 1)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        let startIndex = max(lines.count - lineCount, 0)
        let slice = lines[startIndex...]
        return (["File: \(path.path)"] + slice.enumerated().map { index, line in
            "\(startIndex + index + 1)\t\(line)"
        }).joined(separator: "\n")
    }
}

struct TextSortTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let unique: Bool?
    }

    static let name = "text.sort"
    static let description = "Sorts the lines of a local text file and returns the sorted output."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"unique":{"type":"boolean"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let lines = try String(contentsOf: path, encoding: .utf8)
            .components(separatedBy: .newlines)
        let sortedLines = lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let outputLines = input.unique == true
            ? Array(Set(sortedLines)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            : sortedLines
        guard !outputLines.isEmpty else {
            return "File: \(path.path)\n<empty>"
        }
        return (["File: \(path.path)"] + outputLines).joined(separator: "\n")
    }
}

struct TextWordCountTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let filePath: String?
        let file_path: String?
    }

    static let name = "text.wc"
    static let description = "Counts lines, words, and characters in a local text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let fileURL = try LocalToolsSupport.requiredPath(
            input.path,
            input.file_path,
            input.filePath,
            context: context
        )
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = contents.isEmpty ? 0 : contents.components(separatedBy: .newlines).count
        let words = contents.split { $0.isWhitespace || $0.isNewline }.count
        let characters = contents.count
        return """
        File: \(fileURL.path)
        lines: \(lines)
        words: \(words)
        characters: \(characters)
        """
    }
}

struct LocalWriteFileTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let content: String?
        let createDirectories: Bool?
    }

    static let name = "local.writeFile"
    static let description = "Creates or overwrites a UTF-8 text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"content":{"type":"string"},"createDirectories":{"type":"boolean"}},"required":["file_path","content"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let content = input.content ?? ""
        if input.createDirectories == true {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try content.write(to: path, atomically: true, encoding: .utf8)
        return "Wrote \(path.path) (\(content.utf8.count) bytes)."
    }
}

struct LocalReplaceTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let oldString: String?
        let old_string: String?
        let newString: String?
        let new_string: String?
    }

    static let name = "local.replace"
    static let description = "Replaces all occurrences of oldString with newString in a UTF-8 text file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"}},"required":["path","oldString","newString"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let oldString = try LocalToolsSupport.requiredString(input.oldString, input.old_string, name: "oldString")
        let newString = input.newString ?? input.new_string ?? ""
        let original = try String(contentsOf: path, encoding: .utf8)
        let occurrences = original.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path).")
        }
        let updated = original.replacingOccurrences(of: oldString, with: newString)
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return "Replaced \(occurrences) occurrence(s) in \(path.path)."
    }
}

struct LocalEditFileTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let oldString: String?
        let old_string: String?
        let newString: String?
        let new_string: String?
        let replaceAll: Bool?
        let replace_all: Bool?
    }

    static let name = "local.editFile"
    static let description = "Applies a targeted string replacement in a file. By default exactly one occurrence must match; set replaceAll=true to update every occurrence."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}},"required":["path","oldString","newString"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let oldString = try LocalToolsSupport.requiredString(input.oldString, input.old_string, name: "oldString")
        let newString = input.newString ?? input.new_string ?? ""
        let replaceAll = input.replaceAll ?? input.replace_all ?? false
        let original = try String(contentsOf: path, encoding: .utf8)
        let occurrences = original.components(separatedBy: oldString).count - 1
        guard occurrences > 0 else {
            throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path).")
        }
        if !replaceAll && occurrences != 1 {
            throw LocalToolsFeatureError.permissionDenied("oldString matched \(occurrences) times. Set replaceAll=true or provide a unique string.")
        }
        let updated = replaceAll
            ? original.replacingOccurrences(of: oldString, with: newString)
            : original.replacingFirstOccurrence(of: oldString, with: newString)
        try updated.write(to: path, atomically: true, encoding: .utf8)
        return "Updated \(path.path). Replacements: \(replaceAll ? occurrences : 1)."
    }
}

struct LocalMultiEditTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let edits: [Edit]
    }

    struct Edit: Decodable, Sendable {
        let oldString: String?
        let old_string: String?
        let newString: String?
        let new_string: String?
        let replaceAll: Bool?
        let replace_all: Bool?
    }

    static let name = "local.multiEdit"
    static let description = "Applies multiple targeted edits to the same file in order."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"edits":{"type":"array","items":{"type":"object","properties":{"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}}}}},"required":["path","edits"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        guard !input.edits.isEmpty else {
            throw LocalToolsFeatureError.missingArgument("edits")
        }
        var contents = try String(contentsOf: path, encoding: .utf8)
        var totalReplacements = 0
        for (index, edit) in input.edits.enumerated() {
            let oldString = try LocalToolsSupport.requiredString(
                edit.oldString,
                edit.old_string,
                name: "edits[\(index)].oldString"
            )
            let newString = edit.newString ?? edit.new_string ?? ""
            let replaceAll = edit.replaceAll ?? edit.replace_all ?? false
            let occurrences = contents.components(separatedBy: oldString).count - 1
            guard occurrences > 0 else {
                throw LocalToolsFeatureError.permissionDenied("oldString was not found in \(path.path): \(oldString)")
            }
            if !replaceAll && occurrences != 1 {
                throw LocalToolsFeatureError.permissionDenied("oldString matched \(occurrences) times. Set replaceAll=true or provide a unique string.")
            }
            contents = replaceAll
                ? contents.replacingOccurrences(of: oldString, with: newString)
                : contents.replacingFirstOccurrence(of: oldString, with: newString)
            totalReplacements += replaceAll ? occurrences : 1
        }
        try contents.write(to: path, atomically: true, encoding: .utf8)
        return "Edited \(totalReplacements) occurrence(s) across \(input.edits.count) edit(s) in \(path.path)."
    }
}

struct LocalAppendTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let file_path: String?
        let content: String?
    }

    static let name = "local.append"
    static let description = "Appends UTF-8 text to a file."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, input.file_path, context: context)
        let content = input.content ?? ""
        let data = Data(content.utf8)
        if FileManager.default.fileExists(atPath: path.path) {
            let handle = try FileHandle(forWritingTo: path)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: path)
        }
        return "Appended \(data.count) bytes to \(path.path)."
    }
}

struct LocalMakeDirectoryTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let createIntermediateDirectories: Bool?
    }

    static let name = "local.mkdir"
    static let description = "Creates a directory."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"createIntermediateDirectories":{"type":"boolean"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        try FileManager.default.createDirectory(
            at: path,
            withIntermediateDirectories: input.createIntermediateDirectories ?? true
        )
        return "Created directory \(path.path)."
    }
}

struct LocalDeleteTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let path: String?
        let recursive: Bool?
    }

    static let name = "local.delete"
    static let description = "Deletes a file or directory. Directories require recursive=true."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let path = try LocalToolsSupport.requiredPath(input.path, nil, context: context)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
            return "Path does not exist: \(path.path)"
        }
        if isDirectory.boolValue && input.recursive != true {
            throw LocalToolsFeatureError.permissionDenied("Refusing to delete directory without recursive=true.")
        }
        try FileManager.default.removeItem(at: path)
        return "Deleted \(path.path)."
    }
}

struct LocalMoveTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let sourcePath: String?
        let destinationPath: String?
        let overwriteExisting: Bool?
    }

    static let name = "local.move"
    static let description = "Moves or renames a file or directory."
    static let inputSchema = #"{"type":"object","properties":{"sourcePath":{"type":"string"},"destinationPath":{"type":"string"},"overwriteExisting":{"type":"boolean"}},"required":["sourcePath","destinationPath"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        guard let sourcePath = input.sourcePath?.nilIfBlank,
              let destinationPath = input.destinationPath?.nilIfBlank else {
            throw LocalToolsFeatureError.missingArgument("sourcePath/destinationPath")
        }
        let sourceURL = context.resolvePath(sourcePath)
        let destinationURL = context.resolvePath(destinationPath)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard input.overwriteExisting == true else {
                throw LocalToolsFeatureError.permissionDenied("Destination exists. Set overwriteExisting=true.")
            }
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        return "Moved \(sourceURL.path) to \(destinationURL.path)."
    }
}

public enum MLXLocalFeatureTools {
    public static func fileTools() -> [AnyMLXFeatureTool] {
        [
            AnyMLXFeatureTool(LocalPwdTool()),
            AnyMLXFeatureTool(LocalListDirectoryTool()),
            AnyMLXFeatureTool(LocalReadFileTool()),
            AnyMLXFeatureTool(LocalWriteFileTool()),
            AnyMLXFeatureTool(LocalReplaceTool()),
            AnyMLXFeatureTool(LocalEditFileTool()),
            AnyMLXFeatureTool(LocalMultiEditTool()),
            AnyMLXFeatureTool(LocalAppendTool()),
            AnyMLXFeatureTool(LocalMakeDirectoryTool()),
            AnyMLXFeatureTool(LocalDeleteTool()),
            AnyMLXFeatureTool(LocalMoveTool())
        ]
    }

    public static func searchTools() -> [AnyMLXFeatureTool] {
        [
            AnyMLXFeatureTool(SearchGlobTool()),
            AnyMLXFeatureTool(SearchGrepTool())
        ]
    }

    public static func textTools() -> [AnyMLXFeatureTool] {
        [
            AnyMLXFeatureTool(TextHeadTool()),
            AnyMLXFeatureTool(TextTailTool()),
            AnyMLXFeatureTool(TextSortTool()),
            AnyMLXFeatureTool(TextWordCountTool())
        ]
    }
}

private enum LocalToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .permissionDenied(message):
            return message
        }
    }
}

private enum LocalToolsSupport {
    static func requiredPath(
        _ paths: String?...,
        context: MLXFeatureContext
    ) throws -> URL {
        guard let path = paths.compactMap({ $0?.nilIfBlank }).first else {
            throw LocalToolsFeatureError.missingArgument("path")
        }
        return context.resolvePath(path)
    }

    static func requiredString(
        _ values: String?...,
        name: String
    ) throws -> String {
        guard let value = values.compactMap({ $0?.nilIfBlank }).first else {
            throw LocalToolsFeatureError.missingArgument(name)
        }
        return value
    }

    static func listDirectory(_ url: URL, includeHidden: Bool) throws -> String {
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: includeHidden ? [] : [.skipsHiddenFiles]
        )
        guard !entries.isEmpty else {
            return "<empty>"
        }
        return try entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { entry in
                let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                return isDirectory ? "\(entry.lastPathComponent)/" : entry.lastPathComponent
            }
            .joined(separator: "\n")
    }

    static func readFile(_ url: URL, offset: Int?, limit: Int?) throws -> String {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let startIndex = max((offset ?? 1) - 1, 0)
        let endIndex = min(
            lines.count,
            startIndex + max(limit ?? min(lines.count, 240), 1)
        )
        guard startIndex < endIndex else {
            return "<empty>"
        }
        return (startIndex..<endIndex)
            .map { index in "\(index + 1)\t\(lines[index])" }
            .joined(separator: "\n")
    }

    static func glob(input: SearchGlobTool.Input, context: MLXFeatureContext) throws -> String {
        var pattern = input.pattern?.nilIfBlank
        let root: URL
        if input.path?.nilIfBlank == nil,
           let rawPattern = pattern,
           let patternPath = existingGlobPatternPath(rawPattern, context: context) {
            root = patternPath
            pattern = nil
        } else {
            root = context.resolvePath(input.path ?? ".")
        }
        let maxResults = max(1, input.maxResults ?? input.max_results ?? 200)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return "<empty>"
        }
        var matches: [String] = []
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(root.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !relative.isEmpty else {
                continue
            }
            let isMatch: Bool
            if let pattern {
                isMatch = fnmatch(pattern, relative, 0) == 0
                    || fnmatch(pattern, url.lastPathComponent, 0) == 0
            } else {
                isMatch = true
            }
            if isMatch {
                matches.append(relative)
                if matches.count >= maxResults {
                    break
                }
            }
        }
        return matches.isEmpty ? "<empty>" : matches.joined(separator: "\n")
    }

    static func existingGlobPatternPath(_ pattern: String, context: MLXFeatureContext) -> URL? {
        guard !pattern.contains("*"),
              !pattern.contains("?"),
              !pattern.contains("[") else {
            return nil
        }

        let url = context.resolvePath(pattern)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return url
    }

    static func renderProcessResult(_ result: MLXFeatureProcessResult) -> String {
        var sections = ["exit_code: \(result.exitCode)"]
        if result.timedOut {
            sections.append("timed_out: true")
        }
        if !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stdout:\n\(result.stdout)")
        }
        if !result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("stderr:\n\(result.stderr)")
        }
        if sections.count == 1 {
            sections.append("<no output>")
        }
        return sections.joined(separator: "\n")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func replacingFirstOccurrence(of target: String, with replacement: String) -> String {
        guard let range = range(of: target) else {
            return self
        }
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
