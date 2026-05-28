//
//  Split from DirectMLXAgentRuntime.swift
//  MLXCoder
//

import Foundation

public struct DirectToolDescriptor: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: String

    public init(
        name: String,
        description: String,
        inputSchema: String
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum DirectToolCatalog {
    public static var baseDescriptors: [DirectToolDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        filesystemDescriptors + macOSProcessDescriptors + memoryDescriptors + orchestrationDescriptors + subAgentDescriptors
#else
        filesystemDescriptors + memoryDescriptors + orchestrationDescriptors + subAgentDescriptors
#endif
    }

    public static let filesystemDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "local.pwd",
            description: "Returns the current working directory used by local tools.",
            inputSchema: #"{"type":"object","properties":{}}"#
        ),
        DirectToolDescriptor(
            name: "local.ls",
            description: "Lists files and directories. Paths may be absolute or relative to the working directory.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"includeHidden":{"type":"boolean"}}}"#
        ),
        DirectToolDescriptor(
            name: "local.readFile",
            description: "Reads a UTF-8 text file with line numbers. Use offset and limit for focused reads.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"offset":{"type":"number"},"limit":{"type":"number"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "search.glob",
            description: "Finds files under a local path. Pass pattern for a glob such as **/*.swift; omit pattern to list files recursively.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "local.writeFile",
            description: "Creates or overwrites a UTF-8 text file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"content":{"type":"string"},"createDirectories":{"type":"boolean"}},"required":["file_path","content"]}"#
        ),
        DirectToolDescriptor(
            name: "local.replace",
            description: "Replaces a string in a UTF-8 text file. By default exactly one occurrence must match.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"file_path":{"type":"string"},"oldString":{"type":"string"},"old_string":{"type":"string"},"newString":{"type":"string"},"new_string":{"type":"string"},"replaceAll":{"type":"boolean"},"replace_all":{"type":"boolean"}},"required":["path","oldString","newString"]}"#
        ),
        DirectToolDescriptor(
            name: "local.append",
            description: "Appends UTF-8 text to a file.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}"#
        ),
        DirectToolDescriptor(
            name: "local.mkdir",
            description: "Creates a directory.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"createIntermediateDirectories":{"type":"boolean"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "local.delete",
            description: "Deletes a file or directory. Directories require recursive=true.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"recursive":{"type":"boolean"}},"required":["path"]}"#
        ),
        DirectToolDescriptor(
            name: "local.move",
            description: "Moves or renames a file or directory.",
            inputSchema: #"{"type":"object","properties":{"sourcePath":{"type":"string"},"destinationPath":{"type":"string"},"overwriteExisting":{"type":"boolean"}},"required":["sourcePath","destinationPath"]}"#
        )
    ]

    public static let memoryDescriptors: [DirectToolDescriptor] = MLXMemoryTool.toolDescriptors.map {
        DirectToolDescriptor(
            name: $0.name,
            description: $0.description,
            inputSchema: $0.inputSchema
        )
    }

#if canImport(Darwin) || canImport(Glibc)
    public static let macOSProcessDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "search.grep",
            description: "Searches text with grep from a local path.",
            inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"}},"required":["pattern"]}"#
        ),
        DirectToolDescriptor(
            name: "local.exec",
            description: "Runs a shell command in the working directory and returns stdout, stderr, and exit code.",
            inputSchema: #"{"type":"object","properties":{"command":{"type":"string"},"cwd":{"type":"string"},"workingDirectory":{"type":"string"},"timeoutSeconds":{"type":"number"},"timeout":{"type":"number"}},"required":["command"]}"#
        ),
        DirectToolDescriptor(
            name: "git.status",
            description: "Runs git status --short --branch in the working directory.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.diff",
            description: "Runs git diff. Pass staged=true for --staged.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"staged":{"type":"boolean"},"cached":{"type":"boolean"},"file":{"type":"string"},"file_path":{"type":"string"},"baseRevision":{"type":"string"},"base_revision":{"type":"string"},"base":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.show",
            description: "Runs git show for a revision or object.",
            inputSchema: #"{"type":"object","properties":{"revision":{"type":"string"},"rev":{"type":"string"},"commit":{"type":"string"},"path":{"type":"string"},"file_path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "git.log",
            description: "Runs git log --oneline.",
            inputSchema: #"{"type":"object","properties":{"path":{"type":"string"},"workingDirectory":{"type":"string"},"cwd":{"type":"string"},"limit":{"type":"number"},"n":{"type":"number"}}}"#
        )
    ]
#endif

    public static let orchestrationDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "todo.read",
            description: "Returns the session todo list.",
            inputSchema: #"{"type":"object","properties":{}}"#
        ),
        DirectToolDescriptor(
            name: "todo.write",
            description: "Creates or updates the session todo list. Supports replace, append, and upsert modes.",
            inputSchema: #"{"type":"object","properties":{"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"}},"required":["content"]}},"items":{"type":"array","items":{"type":"object"}},"id":{"type":"string"},"content":{"type":"string"},"title":{"type":"string"},"status":{"type":"string"},"mode":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "task.create",
            description: "Creates one or more session tasks. Prefer a single call with a tasks array when creating multiple tasks.",
            inputSchema: #"{"type":"object","properties":{"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"status":{"type":"string"},"priority":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"output":{"type":"string"},"tasks":{"type":"array","items":{"type":"object"}},"items":{"type":"array","items":{"type":"object"}}}}"#
        ),
        DirectToolDescriptor(
            name: "task.list",
            description: "Lists session tasks, optionally filtered by status or assignee.",
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string"},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"agentID":{"type":"string"},"agent_id":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "task.get",
            description: "Returns a single session task by id.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"}},"required":["id"]}"#
        ),
        DirectToolDescriptor(
            name: "task.update",
            description: "Updates fields on a session task by id.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"taskID":{"type":"string"},"task_id":{"type":"string"},"title":{"type":"string"},"name":{"type":"string"},"details":{"type":"string"},"description":{"type":"string"},"status":{"type":"string"},"priority":{"type":"string"},"dependsOn":{"type":"array","items":{"type":"string"}},"depends_on":{"type":"array","items":{"type":"string"}},"assigneeAgentID":{"type":"string"},"assignee_agent_id":{"type":"string"},"output":{"type":"string"}},"required":["id"]}"#
        )
    ]

    public static let subAgentDescriptors: [DirectToolDescriptor] = [
        DirectToolDescriptor(
            name: "agent.create",
            description: "Creates one or more delegated sub-agents. Each sub-agent inherits the parent session's enabled tools by default. Use isolationMode=report for read-only investigation and isolationMode=implementation for scoped code changes.",
            inputSchema: #"{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"isolationMode":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}},"agents":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"role":{"type":"string"},"prompt":{"type":"string"},"message":{"type":"string"},"isolationMode":{"type":"string"},"toolNames":{"type":"array","items":{"type":"string"}}}}},"items":{"type":"array","items":{"type":"object"}}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.list",
            description: "Lists delegated sub-agents, optionally filtered by status.",
            inputSchema: #"{"type":"object","properties":{"status":{"type":"string"}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.get",
            description: "Returns status and latest output for delegated sub-agents. Reference an agent by id, name, task_id, or ids.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.message",
            description: "Queues a follow-up prompt for one or more delegated sub-agents. Reference an agent by id, name, task_id, or ids.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"message":{"type":"string"},"prompt":{"type":"string"},"input":{"type":"string"}},"required":["message"]}"#
        ),
        DirectToolDescriptor(
            name: "agent.wait",
            description: "Waits until delegated sub-agents finish their pending work or a timeout elapses.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"},"ids":{"type":"array","items":{"type":"string"}},"timeoutSeconds":{"type":"number"},"pollIntervalSeconds":{"type":"number"}}}"#
        ),
        DirectToolDescriptor(
            name: "agent.close",
            description: "Closes a delegated sub-agent and cancels pending work.",
            inputSchema: #"{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"task_id":{"type":"string"}}}"#
        )
    ]

}

extension DirectToolDescriptor {
    public var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: description,
            inputSchema: inputSchema
        )
    }

    public var schemaObject: Any? {
        guard let data = inputSchema.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }
}

public struct AgentToolProviderRegistry: Sendable {
    public var providers: [AgentToolProvider] = []

    public mutating func update(_ providers: [AgentToolProvider]) {
        self.providers = providers
    }

    public var descriptors: [DirectToolDescriptor] {
        ToolDescriptor.canonicalized(providers.flatMap(\.tools)).map {
            DirectToolDescriptor(
                name: $0.name,
                description: $0.description,
                inputSchema: $0.inputSchema
            )
        }
    }

    public func executor(for toolName: String) -> AgentToolExecutor? {
        for provider in providers where provider.tools.contains(where: { $0.name == toolName }) {
            return provider.executor
        }
        return nil
    }
}
