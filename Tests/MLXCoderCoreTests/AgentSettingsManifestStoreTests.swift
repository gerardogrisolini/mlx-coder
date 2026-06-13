import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct AgentSettingsManifestStoreTests {
    @Test
    func subscriptionCredentialSaveCreatesSettingsAfterCachedMissingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-settings-\(UUID().uuidString)", isDirectory: true)
        MLXAppStorageDirectory.configureSupportDirectoryURL(directory)
        AgentSettingsManifestStore.resetDefaultCacheForTesting()
        defer {
            AgentSettingsManifestStore.resetDefaultCacheForTesting()
            MLXAppStorageDirectory.configureSupportDirectoryURL(nil)
            try? FileManager.default.removeItem(at: directory)
        }

        #expect(AgentSettingsManifestStore.load() == nil)

        let chatGPTCredentials = CodexAgentCredentials(
            accessToken: "chat-access",
            refreshToken: "chat-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            accountID: "chat-account"
        )
        try CodexAgentModel.saveCredentials(chatGPTCredentials)

        let anthropicCredentials = AnthropicSubscriptionCredentials(
            accessToken: "anthropic-access",
            refreshToken: "anthropic-refresh",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_100),
            scope: "org:create_api_key user:profile"
        )
        try AnthropicSubscriptionAuthService.saveCredentials(anthropicCredentials)

        let manifest = try AgentSettingsManifestStore.loadRequired()
        #expect(manifest.models.isEmpty)
        #expect(manifest.chatGPTSubscriptionCredentials == chatGPTCredentials)
        #expect(manifest.anthropicSubscriptionCredentials == anthropicCredentials)
    }
}
