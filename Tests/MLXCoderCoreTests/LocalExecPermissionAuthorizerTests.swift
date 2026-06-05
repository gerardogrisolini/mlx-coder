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
}
