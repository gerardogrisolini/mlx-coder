import Foundation
import MLXCoderCore
import Testing

@Suite
struct MLXMemoryServiceTests {
    @Test
    func memoryTemplatesDescribeGlobalAndProjectResponsibilities() {
        #expect(MLXMemoryService.defaultGlobalMemoryContent.contains("general preferences"))
        #expect(MLXMemoryService.defaultGlobalMemoryContent.contains("cross-project guidance"))
        #expect(MLXMemoryService.defaultProjectMemoryContent.contains("architecture decisions"))
        #expect(MLXMemoryService.defaultProjectMemoryContent.contains("significant completed features"))
        #expect(MLXMemoryService.toolUsagePromptSection().contains("where previous work should resume"))
        #expect(MLXMemoryService.toolUsagePromptSection().contains("Write project resume points only"))

        let projectDefault = MLXProjectContextFileService.defaultContent(
            kind: .memory,
            projectName: "TestProject",
            rootPath: "/tmp/TestProject"
        )
        #expect(projectDefault == MLXMemoryService.defaultProjectMemoryContent)
    }

    @Test
    func templateGuidanceBulletsAreNotParsedAsMemoryEntries() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        try service.ensureGlobalMemoryFileExists()
        try MLXMemoryService.defaultProjectMemoryContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(
                to: workspaceURL.appendingPathComponent(MLXMemoryService.filename),
                atomically: true,
                encoding: .utf8
            )

        #expect(
            service.readEntries(
                scope: .global,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).isEmpty
        )
        #expect(
            service.readEntries(
                scope: .project,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).isEmpty
        )
    }

    @Test
    func globalAndProjectWritesUseDifferentMemoryTemplates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)

        try service.writeEntry(
            content: "Preference: keep final summaries concise.",
            scope: .global,
            workspaceRootURL: workspaceURL
        )
        try service.writeEntry(
            content: "Architecture decision: use direct mlx-coder runtime inside mlx-server.",
            scope: .project,
            workspaceRootURL: workspaceURL
        )

        let globalContent = try String(contentsOf: service.globalMemoryFileURL(), encoding: .utf8)
        let projectContent = try String(
            contentsOf: workspaceURL.appendingPathComponent(MLXMemoryService.filename),
            encoding: .utf8
        )

        #expect(globalContent.contains("Durable global memory"))
        #expect(globalContent.contains("Preference: keep final summaries concise."))
        #expect(projectContent.contains("Durable project memory"))
        #expect(projectContent.contains("Architecture decision: use direct mlx-coder runtime inside mlx-server."))
        #expect(
            service.readEntries(
                scope: .global,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).count == 1
        )
        #expect(
            service.readEntries(
                scope: .project,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).count == 1
        )
    }

    @Test
    func memorySearchPrioritizesProjectEntriesWhenScopeIsAll() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        try service.writeEntry(
            content: "Architecture note: global reusable preference.",
            scope: .global,
            workspaceRootURL: workspaceURL
        )
        try service.writeEntry(
            content: "Architecture note: project-specific runtime decision.",
            scope: .project,
            workspaceRootURL: workspaceURL
        )

        let output = try MLXMemoryTool.execute(
            ToolRequest(
                name: "memory.search",
                arguments: ["query": .string("architecture")]
            ),
            context: MLXMemoryToolContext(workingDirectory: workspaceURL),
            memoryService: service
        )
        guard case let .object(result)? = output.rawResult,
              case let .array(entries)? = result["entries"],
              case let .object(firstEntry)? = entries.first else {
            Issue.record("Expected memory.search to return JSON entries.")
            return
        }

        #expect(firstEntry["scope"] == .string("project"))
    }

    @Test
    func standalonePromptOmitsMemoryInstructionsWhenMemoryToolIsDisabled() {
        let prompt = AgentStandaloneSystemPrompt.prompt(
            cwd: "/tmp/project",
            memoryToolEnabled: false
        )

        #expect(!prompt.contains("Memory tools:"))
        #expect(!prompt.contains("`memory.write`"))
        #expect(!prompt.contains("memory, and delegated sub-agent tools"))
    }

    @Test
    func defaultAgentPromptFollowsActiveMemoryToolState() {
        let defaultAgent = AgentProfileStore.defaultProfiles()[0]
        let withoutMemory = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: "/tmp/project",
            selectedAgent: defaultAgent,
            allowedToolNames: []
        )
        let withMemory = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: "/tmp/project",
            selectedAgent: defaultAgent,
            allowedToolNames: ["memory.read", "memory.write"]
        )

        #expect(!withoutMemory.contains("Memory tools:"))
        #expect(!withoutMemory.contains("`memory.write`"))
        #expect(!withoutMemory.contains("memory, and delegated sub-agent tools"))
        #expect(withMemory.contains("Memory tools:"))
        #expect(withMemory.contains("`memory.write`"))
        #expect(withMemory.contains("memory, and delegated sub-agent tools"))
    }

    @Test
    func defaultAgentProfilesIncludeRecommendedOperatingModes() throws {
        let profiles = AgentProfileStore.defaultProfiles()
        let names = Set(profiles.map(\.name))

        #expect(names == Set([
            "Default",
            "Bugfix",
            "Feature",
            "Review",
            "Research",
            "Refactor"
        ]))
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        #expect(try AgentProfileStore.defaultProfile(in: profiles).name == "Default")
    }
}
