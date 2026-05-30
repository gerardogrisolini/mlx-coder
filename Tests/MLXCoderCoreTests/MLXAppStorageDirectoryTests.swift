import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct MLXAppStorageDirectoryTests {
    @Test
    func coderSupportFilesDefaultToHomeMlxCoderDirectory() {
        let supportDirectory = MLXUserHomeDirectory.current()
            .appendingPathComponent(".mlx-coder", isDirectory: true)
            .standardizedFileURL

        #expect(MLXAppStorageDirectory.defaultSupportDirectoryURL() == supportDirectory)
        #expect(MLXCoderSupportFileService.supportDirectoryURL() == supportDirectory)
        #expect(MLXAgentsContextService().globalAgentsFileURL() == supportDirectory.appendingPathComponent("AGENTS.md"))
        #expect(MLXMemoryService().globalMemoryFileURL() == supportDirectory.appendingPathComponent("MEMORY.md"))
        #expect(AgentSettingsManifestStore.settingsURL() == supportDirectory.appendingPathComponent("settings.json"))
        #expect(AgentProfileStore.agentsManifestURL() == supportDirectory.appendingPathComponent("agents.json"))
    }
}
