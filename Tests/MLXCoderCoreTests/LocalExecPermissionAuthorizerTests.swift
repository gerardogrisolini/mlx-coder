@testable import MLXCoderCore
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
        let manifest = AgentSettingsManifest(
            models: [],
            localExecAllowedCommands: [
                "swift",
                "pwd && echo ok"
            ]
        )

        #expect(LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed("swift test --filter MLXCoderCoreTests", manifest: manifest))
        #expect(LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed("pwd && echo ok", manifest: manifest))
        #expect(LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed("  pwd && echo ok  ", manifest: manifest))
        #expect(!LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed("pwd && echo no", manifest: manifest))
    }
}
