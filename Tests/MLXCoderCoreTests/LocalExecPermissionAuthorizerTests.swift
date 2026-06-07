@testable import MLXCoderCore
import Foundation
import Testing

@Suite
struct LocalExecPermissionAuthorizerTests {
    @Test
    func commandPermissionIdentityIgnoresArguments() {
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "swift test --filter MLXCoderCoreTests") == "swift")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "git status --short --branch") == "git")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "python3 --version") == "python3")
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "xcodebuild -list") == "xcodebuild")
    }

    @Test
    func commandPermissionIdentityRejectsShellComposition() {
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "ls -la > out.txt") == nil)
        #expect(LocalExecPermissionAuthorizer.commandPermissionIdentity(for: "pwd && rm -rf tmp") == nil)
    }

    @Test
    func persistedCommandPermissionIdentityFallsBackToFullCommand() {
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "swift test --filter MLXCoderCoreTests") == "swift")
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "pwd && echo ok") == "pwd && echo ok")
        #expect(LocalExecPermissionAuthorizer.persistedCommandPermissionIdentity(for: "\n  echo ok > out.txt  \n") == "echo ok > out.txt")
    }

    @Test
    func persistedAllowedCommandsMatchSimpleAndComposedCommands() {
        let permissions = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift",
                "pwd && echo ok"
            ]
        )

        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "swift test --filter MLXCoderCoreTests",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "pwd && echo ok",
                permissions: permissions
            )
        )
        #expect(
            LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "  pwd && echo ok  ",
                permissions: permissions
            )
        )
        #expect(
            !LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(
                "pwd && echo no",
                permissions: permissions
            )
        )
    }

    @Test
    func settingsManifestDecodesButDoesNotEncodeLegacyLocalExecPermissions() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            localExecAllowedCommands: [
                "swift"
            ]
        )

        let data = try JSONEncoder().encode(manifest)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("localExecAllowedCommands"))

        let legacyData = Data(
            #"""
            {
              "version": 8,
              "models": [],
              "localExecAllowedCommands": ["swift"]
            }
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: legacyData)
        #expect(decoded.localExecAllowedCommands == ["swift"])
    }

    @Test
    func permissionsManifestRoundTripsLocalExecPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-permissions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let url = directory.appendingPathComponent("permissions.json")

        let manifest = AgentPermissionsManifest(
            localExecAllowedCommands: [
                "swift",
                "swift",
                " pwd && echo ok "
            ]
        )
        try AgentPermissionsManifestStore.save(manifest, to: url)
        let decoded = try AgentPermissionsManifestStore.loadRequired(from: url)

        #expect(decoded.localExecAllowedCommands == ["swift", "pwd && echo ok"])
        #expect(decoded.containsLocalExecAllowedCommand("SWIFT"))
    }
}
