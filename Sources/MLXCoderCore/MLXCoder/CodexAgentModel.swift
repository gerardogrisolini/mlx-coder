//
//  CodexAgentModel.swift
//  SwiftMLX
//
//  Created by Codex on 13/05/26.
//

import Foundation
#if os(macOS)
import Security
#endif

public struct CodexAgentCredentials: Codable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let accountID: String

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        accountID: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountID = accountID
    }

    public var isExpiredOrNearlyExpired: Bool {
        expiresAt.timeIntervalSinceNow <= 60
    }
}

private enum CodexAgentCredentialError: LocalizedError {
    case missingCredentials
    case invalidCredentials
    case missingAccessToken
    case missingRefreshToken
    case missingAccountID
    case invalidJWT
    case tokenExchangeFailed(status: Int, body: String)
    case invalidTokenResponse
    case keychain(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "ChatGPT Subscription is not connected. Sign in from Settings, then try again."
        case .invalidCredentials:
            return "ChatGPT Subscription credentials could not be read."
        case .missingAccessToken:
            return "ChatGPT Subscription credentials do not contain an access token."
        case .missingRefreshToken:
            return "ChatGPT Subscription credentials do not contain a refresh token."
        case .missingAccountID:
            return "ChatGPT Subscription credentials do not contain a ChatGPT account id."
        case .invalidJWT:
            return "ChatGPT Subscription access token could not be decoded."
        case let .tokenExchangeFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT Subscription token refresh failed with HTTP \(status)."
            }
            return "ChatGPT Subscription token refresh failed with HTTP \(status): \(detail)"
        case .invalidTokenResponse:
            return "ChatGPT Subscription token refresh returned an invalid response."
        case let .keychain(status):
            return "ChatGPT Subscription credentials could not be stored in Keychain (\(status))."
        }
    }
}

public nonisolated enum CodexAgentModel {
    public struct ModelOption: Identifiable, Hashable, Sendable {
        public let modelID: String
        public let title: String
        public let subtitle: String
        public let contextWindowTokenLimit: Int?

        public var id: String { modelID }
        public var llmID: String {
            CodexAgentModel.selectionID(forModelID: modelID)
        }
    }

    public static let llmID = "chatgpt"
    public static let legacyLLMID = "codex"
    public static let defaultModelID = "gpt-5.5"
    public static var defaultLLMID: String {
        selectionID(forModelID: defaultModelID)
    }
    public static let modelID = defaultModelID
    public static let contextWindowTokenLimit = 272_000
    public static let displayTitle = "ChatGPT Subscription"
    public static let displaySubtitle = "ChatGPT Plus/Pro"
    public static let availableModels: [ModelOption] = [
        ModelOption(
            modelID: "gpt-5.5",
            title: "GPT-5.5",
            subtitle: "Frontier model",
            contextWindowTokenLimit: contextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.4",
            title: "GPT-5.4",
            subtitle: "Everyday coding",
            contextWindowTokenLimit: contextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.4-mini",
            title: "GPT-5.4 Mini",
            subtitle: "Fast small model",
            contextWindowTokenLimit: contextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.3-codex",
            title: "GPT-5.3 Codex",
            subtitle: "Coding-optimized",
            contextWindowTokenLimit: contextWindowTokenLimit
        ),
        ModelOption(
            modelID: "gpt-5.3-codex-spark",
            title: "GPT-5.3 Codex Spark",
            subtitle: "Ultra-fast coding",
            contextWindowTokenLimit: 128_000
        ),
        ModelOption(
            modelID: "gpt-5.2",
            title: "GPT-5.2",
            subtitle: "Long-running work",
            contextWindowTokenLimit: contextWindowTokenLimit
        )
    ]
    public static let thinkingSupport = MLXModelThinkingSupport.effort(
        levels: [.low, .medium, .high, .xhigh]
    )

    public static func isCodexLLMID(_ value: String?) -> Bool {
        guard let normalizedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedValue.isEmpty else {
            return false
        }

        return isSubscriptionPrefix(normalizedValue, prefix: llmID)
            || isSubscriptionPrefix(normalizedValue, prefix: legacyLLMID)
    }

    public static func canonicalLLMID(_ value: String?) -> String {
        guard isCodexLLMID(value) else {
            return ""
        }
        return selectionID(forModelID: modelID(fromLLMID: value))
    }

    public static func selectionID(forModelID modelID: String) -> String {
        "\(llmID):\(normalizedModelID(modelID))"
    }

    public static func modelID(fromLLMID value: String?) -> String {
        guard let value else {
            return defaultModelID
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return defaultModelID
        }

        let lowercasedValue = trimmedValue.lowercased()
        if lowercasedValue == llmID || lowercasedValue == legacyLLMID {
            return defaultModelID
        }
        for prefix in [llmID, legacyLLMID] {
            for separator in [":", "/"] where lowercasedValue.hasPrefix(prefix + separator) {
                let rawModelID = String(trimmedValue.dropFirst(prefix.count + separator.count))
                return normalizedModelID(rawModelID)
            }
        }
        return normalizedModelID(trimmedValue)
    }

    public static func option(forLLMID value: String?) -> ModelOption {
        option(forModelID: modelID(fromLLMID: value))
    }

    public static func option(forModelID modelID: String) -> ModelOption {
        let normalizedModelID = normalizedModelID(modelID)
        if let option = availableModels.first(where: { $0.modelID == normalizedModelID }) {
            return option
        }
        return ModelOption(
            modelID: normalizedModelID,
            title: normalizedModelID,
            subtitle: displaySubtitle,
            contextWindowTokenLimit: nil
        )
    }

    public static func selectionTitle(forLLMID value: String?) -> String {
        "\(displayTitle) · \(option(forLLMID: value).title)"
    }

    public static func contextWindowTokenLimit(forLLMID value: String?) -> Int? {
        option(forLLMID: value).contextWindowTokenLimit
    }

    private static func normalizedModelID(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultModelID : trimmedValue
    }

    private static func isSubscriptionPrefix(_ value: String, prefix: String) -> Bool {
        value == prefix
            || value.hasPrefix(prefix + ":")
            || value.hasPrefix(prefix + "/")
    }

    public static var isAvailable: Bool {
        isAuthenticated
    }

    public static var isAuthenticated: Bool {
#if os(macOS)
        (try? loadCredentials()) != nil
#else
        false
#endif
    }

    public static var isReady: Bool {
        isAuthenticated
    }

#if os(macOS)
    public static func loadCredentials() throws -> CodexAgentCredentials {
        if let environmentToken = ProcessInfo.processInfo.environment["CHATGPT_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            let refreshToken = ProcessInfo.processInfo.environment["CHATGPT_REFRESH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? environmentToken
            let accountID = ProcessInfo.processInfo.environment["CHATGPT_ACCOUNT_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? (try? chatGPTAccountID(from: environmentToken))
            guard let accountID else {
                throw CodexAgentCredentialError.missingAccountID
            }
            return CodexAgentCredentials(
                accessToken: environmentToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                accountID: accountID
            )
        }

        return try ChatGPTSubscriptionCredentialStore.load()
    }

    public static func loadValidCredentials() async throws -> CodexAgentCredentials {
        let credentials = try loadCredentials()
        guard credentials.isExpiredOrNearlyExpired else {
            return credentials
        }
        let refreshedCredentials = try await refresh(credentials: credentials)
        try saveCredentials(refreshedCredentials)
        return refreshedCredentials
    }

    public static func saveCredentials(_ credentials: CodexAgentCredentials) throws {
        try ChatGPTSubscriptionCredentialStore.save(credentials)
    }

    public static func removeCredentials() {
        ChatGPTSubscriptionCredentialStore.remove()
    }

    public static func chatGPTAccountID(from token: String) throws -> String {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            throw CodexAgentCredentialError.invalidJWT
        }
        guard let payloadData = base64URLDecodedData(String(parts[1])),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accountID = (auth["chatgpt_account_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty else {
            throw CodexAgentCredentialError.invalidJWT
        }
        return accountID
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func refresh(
        credentials: CodexAgentCredentials
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": "app_EMoamEEZ73f0CkXaXp7hrann"
        ])
    }

    private static func tokenRequest(
        parameters: [String: String]
    ) async throws -> CodexAgentCredentials {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.httpBody = formURLEncodedBody(parameters)
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexAgentCredentialError.invalidTokenResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexAgentCredentialError.tokenExchangeFailed(
                status: httpResponse.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        let tokenResponse = try JSONDecoder().decode(CodexCredentialTokenResponse.self, from: data)
        let accessToken = tokenResponse.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = tokenResponse.refreshToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              !refreshToken.isEmpty,
              tokenResponse.expiresIn > 0 else {
            throw CodexAgentCredentialError.invalidTokenResponse
        }

        return CodexAgentCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            accountID: try chatGPTAccountID(from: accessToken)
        )
    }

    private static func formURLEncodedBody(_ values: [String: String]) -> Data {
        let encoded = values
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(urlEncoded(key))=\(urlEncoded(value))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
#endif
}

#if os(macOS)
private struct CodexCredentialTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private enum ChatGPTSubscriptionCredentialStore {
    private static let service = "MLXCoder.ChatGPTSubscription"
    private static let account = "default"

    static func load() throws -> CodexAgentCredentials {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw CodexAgentCredentialError.missingCredentials
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let credentials = try? JSONDecoder().decode(CodexAgentCredentials.self, from: data),
              !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexAgentCredentialError.invalidCredentials
        }
        return credentials
    }

    static func save(_ credentials: CodexAgentCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery() as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CodexAgentCredentialError.keychain(status: updateStatus)
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CodexAgentCredentialError.keychain(status: addStatus)
        }
    }

    static func remove() {
        SecItemDelete(baseQuery() as CFDictionary)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
