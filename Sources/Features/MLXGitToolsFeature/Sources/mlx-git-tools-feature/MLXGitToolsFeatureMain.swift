//
//  main.swift
//  mlx-git-tools-feature
//

import Foundation
import MLXFeatureKit

struct GitStatusTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
    }

    static let name = "git.status"
    static let description = "Runs git status --short --branch in the working directory."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        try await GitToolsSupport.runGit(["status", "--short", "--branch"], input: input, context: context)
    }
}

struct GitDiffTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let staged: Bool?
        let cached: Bool?
        let file: String?
        let file_path: String?
        let filePath: String?
        let baseRevision: String?
        let base_revision: String?
        let base: String?
    }

    static let name = "git.diff"
    static let description = "Runs git diff. Pass staged=true for --staged."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"staged":{"type":"boolean"},"cached":{"type":"boolean"},"file":{"type":"string"},"file_path":{"type":"string"},"baseRevision":{"type":"string"},"base_revision":{"type":"string"},"base":{"type":"string"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        var args = ["diff"]
        if input.staged == true || input.cached == true {
            args.append("--cached")
        }
        if let baseRevision = firstNonBlank(input.baseRevision, input.base_revision, input.base) {
            args.append(baseRevision)
        }
        if let file = firstNonBlank(input.file, input.file_path, input.filePath, input.path) {
            args.append("--")
            args.append(file)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitShowTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let revision: String?
        let rev: String?
        let commit: String?
        let file: String?
        let file_path: String?
        let filePath: String?
    }

    static let name = "git.show"
    static let description = "Runs git show for a revision or object."
    static let inputSchema = #"{"type":"object","properties":{"revision":{"type":"string"},"rev":{"type":"string"},"commit":{"type":"string"},"path":{"type":"string"},"file_path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        var args = ["show", firstNonBlank(input.revision, input.rev, input.commit) ?? "HEAD"]
        if let file = firstNonBlank(input.file, input.file_path, input.filePath, input.path) {
            args.append("--")
            args.append(file)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitLogTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let limit: Int?
        let n: Int?
    }

    static let name = "git.log"
    static let description = "Runs git log --oneline."
    static let inputSchema = #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"limit":{"type":"number"},"n":{"type":"number"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let limit = max(1, min(input.limit ?? input.n ?? 20, 200))
        return try await GitToolsSupport.runGit(["log", "--oneline", "-n", "\(limit)"], input: input, context: context)
    }
}

struct GitBranchTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let all: Bool?
        let remotes: Bool?
        let contains: String?
    }

    static let name = "git.branch"
    static let description = "Lists local, remote, or all branches."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"all":{"type":"boolean"},"remotes":{"type":"boolean"},"contains":{"type":"string"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        var args = ["branch"]
        if input.all == true {
            args.append("--all")
        } else if input.remotes == true {
            args.append("--remotes")
        }
        if let contains = input.contains?.nilIfBlank {
            args.append(contentsOf: ["--contains", contains])
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitRemoteTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
    }

    static let name = "git.remote"
    static let description = "Lists configured remotes and URLs."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        try await GitToolsSupport.runGit(["remote", "-v"], input: input, context: context)
    }
}

struct GitLsFilesTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let includeUntracked: Bool?
        let maxResults: Int?
        let max_results: Int?
    }

    static let name = "git.lsFiles"
    static let description = "Lists tracked files, optionally including untracked files that are not ignored."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"includeUntracked":{"type":"boolean"},"maxResults":{"type":"number"},"max_results":{"type":"number"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        var args = ["ls-files"]
        if input.includeUntracked == true {
            args.append(contentsOf: ["--cached", "--others", "--exclude-standard"])
        }
        let output = try await GitToolsSupport.runGit(args, input: input, context: context)
        let maxResults = max(1, min(input.maxResults ?? input.max_results ?? 500, 10_000))
        return output.components(separatedBy: .newlines)
            .prefix(maxResults)
            .joined(separator: "\n")
    }
}

struct GitGrepTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let pattern: String?
        let paths: [String]?
        let maxResults: Int?
        let max_results: Int?
    }

    static let name = "git.grep"
    static let description = "Searches tracked repository files with git grep."
    static let inputSchema = #"{"type":"object","properties":{"pattern":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"maxResults":{"type":"number"},"max_results":{"type":"number"}},"required":["pattern"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        guard let pattern = input.pattern?.nilIfBlank else {
            throw GitToolsFeatureError.missingArgument("pattern")
        }
        let maxResults = max(1, min(input.maxResults ?? input.max_results ?? 200, 10_000))
        var args = ["grep", "-n", "-I", "-m", "\(maxResults)", pattern]
        let paths = input.paths ?? input.path.map { [$0] } ?? []
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: paths)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitBlameTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let file: String?
        let file_path: String?
        let startLine: Int?
        let endLine: Int?
    }

    static let name = "git.blame"
    static let description = "Shows git blame for a file, optionally scoped to a line range."
    static let inputSchema = #"{"type":"object","properties":{"file":{"type":"string"},"path":{"type":"string"},"file_path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"startLine":{"type":"number"},"endLine":{"type":"number"}},"required":["file"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        guard let file = firstNonBlank(input.file, input.path, input.file_path) else {
            throw GitToolsFeatureError.missingArgument("file")
        }
        var args = ["blame"]
        if let startLine = input.startLine,
           let endLine = input.endLine {
            args.append(contentsOf: ["-L", "\(startLine),\(endLine)"])
        }
        args.append("--")
        args.append(file)
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitAddTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let paths: [String]?
        let all: Bool?
    }

    static let name = "git.add"
    static let description = "Stages files for commit. Pass paths or all=true."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"all":{"type":"boolean"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        var args = ["add"]
        if input.all == true {
            args.append("-A")
        } else {
            let paths = input.paths ?? input.path.map { [$0] } ?? []
            guard !paths.isEmpty else {
                throw GitToolsFeatureError.missingArgument("paths")
            }
            args.append("--")
            args.append(contentsOf: paths)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitRestoreTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let paths: [String]?
        let staged: Bool?
        let worktree: Bool?
        let discardChanges: Bool?
    }

    static let name = "git.restore"
    static let description = "Unstages files with staged=true, or discards worktree changes only when worktree=true and discardChanges=true."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"}},"staged":{"type":"boolean"},"worktree":{"type":"boolean"},"discardChanges":{"type":"boolean"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let staged = input.staged == true
        let worktree = input.worktree == true
        guard staged || worktree else {
            throw GitToolsFeatureError.missingArgument("staged or worktree")
        }
        if worktree && input.discardChanges != true {
            throw GitToolsFeatureError.permissionDenied("Refusing to discard worktree changes without discardChanges=true.")
        }
        var args = ["restore"]
        if staged {
            args.append("--staged")
        }
        if worktree {
            args.append("--worktree")
        }
        args.append("--")
        args.append(contentsOf: input.paths ?? input.path.map { [$0] } ?? ["."])
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitCommitTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let message: String?
        let all: Bool?
    }

    static let name = "git.commit"
    static let description = "Creates a git commit from staged changes. Pass message for the commit message."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"message":{"type":"string"},"all":{"type":"boolean"}},"required":["message"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        guard let message = input.message?.nilIfBlank else {
            throw GitToolsFeatureError.missingArgument("message")
        }
        var args = ["commit", "-m", message]
        if input.all == true {
            args.insert("-a", at: 1)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitPushTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let remote: String?
        let branch: String?
        let refspec: String?
        let setUpstream: Bool?
        let set_upstream: Bool?
        let forceWithLease: Bool?
        let force_with_lease: Bool?
        let tags: Bool?
        let dryRun: Bool?
        let dry_run: Bool?
    }

    static let name = "git.push"
    static let description = "Pushes commits to a remote. Supports remote, branch/refspec, setUpstream, forceWithLease, tags, and dryRun."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"remote":{"type":"string"},"branch":{"type":"string"},"refspec":{"type":"string"},"setUpstream":{"type":"boolean"},"set_upstream":{"type":"boolean"},"forceWithLease":{"type":"boolean"},"force_with_lease":{"type":"boolean"},"tags":{"type":"boolean"},"dryRun":{"type":"boolean"},"dry_run":{"type":"boolean"}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let setUpstream = input.setUpstream == true || input.set_upstream == true
        let remote = input.remote?.nilIfBlank
        let branchOrRefspec = firstNonBlank(input.branch, input.refspec)
        if setUpstream && (remote == nil || branchOrRefspec == nil) {
            throw GitToolsFeatureError.missingArgument("remote and branch")
        }

        var args = ["push"]
        if input.dryRun == true || input.dry_run == true {
            args.append("--dry-run")
        }
        if setUpstream {
            args.append("--set-upstream")
        }
        if input.forceWithLease == true || input.force_with_lease == true {
            args.append("--force-with-lease")
        }
        if input.tags == true {
            args.append("--tags")
        }
        if let remote {
            args.append(remote)
        }
        if let branchOrRefspec {
            args.append(branchOrRefspec)
        }
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitStashTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let action: String?
        let message: String?
        let stash: String?
        let includeUntracked: Bool?
        let paths: [String]?
    }

    static let name = "git.stash"
    static let description = "Runs git stash list/show/push/apply/pop/drop with structured arguments."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"action":{"type":"string"},"message":{"type":"string"},"stash":{"type":"string"},"includeUntracked":{"type":"boolean"},"paths":{"type":"array","items":{"type":"string"}}}}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        let action = (input.action?.nilIfBlank ?? "list").lowercased()
        let args = try GitToolsSupport.gitStashArguments(action: action, input: input)
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

struct GitSwitchTool: MLXFeatureTool {
    struct Input: Decodable, Sendable, GitWorkingDirectoryInput {
        let path: String?
        let workingDirectory: String?
        let cwd: String?
        let branch: String?
        let create: Bool?
    }

    static let name = "git.switch"
    static let description = "Switches branches, optionally creating the branch when create=true."
    static let inputSchema = #"{"type":"object","properties":{"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"path":{"type":"string"},"branch":{"type":"string"},"create":{"type":"boolean"}},"required":["branch"]}"#

    func run(_ input: Input, context: MLXFeatureContext) async throws -> String {
        guard let branch = input.branch?.nilIfBlank else {
            throw GitToolsFeatureError.missingArgument("branch")
        }
        var args = ["switch"]
        if input.create == true {
            args.append("-c")
        }
        args.append(branch)
        return try await GitToolsSupport.runGit(args, input: input, context: context)
    }
}

@main
struct GitToolsFeatureMain {
    static func main() async {
        await MLXFeatureRunner.run([
            AnyMLXFeatureTool(GitStatusTool()),
            AnyMLXFeatureTool(GitDiffTool()),
            AnyMLXFeatureTool(GitShowTool()),
            AnyMLXFeatureTool(GitLogTool()),
            AnyMLXFeatureTool(GitBranchTool()),
            AnyMLXFeatureTool(GitRemoteTool()),
            AnyMLXFeatureTool(GitLsFilesTool()),
            AnyMLXFeatureTool(GitGrepTool()),
            AnyMLXFeatureTool(GitBlameTool()),
            AnyMLXFeatureTool(GitAddTool()),
            AnyMLXFeatureTool(GitRestoreTool()),
            AnyMLXFeatureTool(GitCommitTool()),
            AnyMLXFeatureTool(GitPushTool()),
            AnyMLXFeatureTool(GitStashTool()),
            AnyMLXFeatureTool(GitSwitchTool())
        ])
    }
}

protocol GitWorkingDirectoryInput {
    var workingDirectory: String? { get }
    var cwd: String? { get }
}

private enum GitToolsSupport {
    static func runGit<T: GitWorkingDirectoryInput>(
        _ arguments: [String],
        input: T,
        context: MLXFeatureContext
    ) async throws -> String {
        let result = try await MLXFeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            workingDirectory: gitWorkingDirectory(input: input, context: context),
            environment: context.environment,
            timeout: 60
        )
        return renderProcessResult(result)
    }

    static func gitWorkingDirectory<T: GitWorkingDirectoryInput>(
        input: T,
        context: MLXFeatureContext
    ) -> URL {
        context.resolvePath(firstNonBlank(input.workingDirectory, input.cwd) ?? ".")
    }

    static func gitStashArguments(action: String, input: GitStashTool.Input) throws -> [String] {
        switch action {
        case "list":
            return ["stash", "list"]
        case "show":
            return ["stash", "show", "--stat", "--patch", input.stash?.nilIfBlank ?? "stash@{0}"]
        case "push", "save":
            var args = ["stash", "push"]
            if let message = input.message?.nilIfBlank {
                args.append(contentsOf: ["-m", message])
            }
            if input.includeUntracked == true {
                args.append("--include-untracked")
            }
            if let paths = input.paths, !paths.isEmpty {
                args.append("--")
                args.append(contentsOf: paths)
            }
            return args
        case "apply", "pop", "drop":
            var args = ["stash", action]
            if let stash = input.stash?.nilIfBlank {
                args.append(stash)
            }
            return args
        default:
            throw GitToolsFeatureError.permissionDenied("Unsupported git stash action: \(action).")
        }
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

private enum GitToolsFeatureError: LocalizedError {
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

private func firstNonBlank(_ values: String?...) -> String? {
    values.compactMap { $0?.nilIfBlank }.first
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
