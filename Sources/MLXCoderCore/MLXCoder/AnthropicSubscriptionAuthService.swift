//
//  AnthropicSubscriptionAuthService.swift
//  MLXCoder
//
//  Created by Codex on 10/06/26.
//

import Foundation
import os
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import AppKit
import CryptoKit
import Network
#endif

public struct AnthropicSubscriptionCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date
    public let scope: String?

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        scope: String? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpiredOrNearlyExpired: Bool {
        expiresAt.timeIntervalSinceNow <= 60
    }
}

public enum AnthropicSubscriptionAuthError: LocalizedError {
    case unsupportedPlatform
    case callbackServerUnavailable
    case callbackCancelled
    case callbackRequestInvalid
    case stateMismatch
    case missingAuthorizationCode
    case missingOAuthState
    case tokenExchangeFailed(status: Int, body: String)
    case invalidTokenResponse
    case browserOpenFailed
    case randomBytesFailed(Int32)
    case missingCredentials
    case invalidCredentials
    case missingAccessToken
    case missingRefreshToken

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Anthropic Subscription browser sign-in is available on macOS."
        case .callbackServerUnavailable:
            return "Unable to start the local Anthropic sign-in callback server."
        case .callbackCancelled:
            return "Anthropic sign-in was cancelled."
        case .callbackRequestInvalid:
            return "Anthropic sign-in callback was invalid."
        case .stateMismatch:
            return "Anthropic sign-in state did not match."
        case .missingAuthorizationCode:
            return "Anthropic sign-in did not return an authorization code."
        case .missingOAuthState:
            return "Anthropic sign-in did not return an OAuth state."
        case let .tokenExchangeFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Anthropic sign-in token exchange failed with HTTP \(status)."
            }
            return "Anthropic sign-in token exchange failed with HTTP \(status): \(detail)"
        case .invalidTokenResponse:
            return "Anthropic sign-in returned an invalid token response."
        case .browserOpenFailed:
            return "Unable to open the Anthropic sign-in page."
        case let .randomBytesFailed(status):
            return "Unable to create Anthropic sign-in verifier (\(status))."
        case .missingCredentials:
            return "Anthropic Subscription is not connected. Sign in from Settings, then try again."
        case .invalidCredentials:
            return "Anthropic Subscription credentials could not be read."
        case .missingAccessToken:
            return "Anthropic Subscription credentials do not contain an access token."
        case .missingRefreshToken:
            return "Anthropic Subscription credentials do not contain a refresh token."
        }
    }
}

#if os(macOS)
public final class AnthropicSubscriptionSignInSession: @unchecked Sendable {
    public let authorizationURL: URL

    private let verifier: String
    private let callbackServer: AnthropicSubscriptionCallbackServer

    fileprivate init(
        authorizationURL: URL,
        verifier: String,
        callbackServer: AnthropicSubscriptionCallbackServer
    ) {
        self.authorizationURL = authorizationURL
        self.verifier = verifier
        self.callbackServer = callbackServer
    }

    public func waitForCredentials() async throws -> AnthropicSubscriptionCredentials {
        defer {
            callbackServer.stop()
        }

        let result = try await callbackServer.waitForAuthorizationResult()
        let credentials = try await AnthropicSubscriptionAuthService.exchangeAuthorizationCode(
            code: result.code,
            state: result.state,
            verifier: verifier
        )
        try AnthropicSubscriptionAuthService.saveCredentials(credentials)
        return credentials
    }

    public func submitAuthorizationInput(_ input: String) throws {
        try callbackServer.submitAuthorizationInput(input)
    }

    public func cancel() {
        callbackServer.stop()
    }
}

public enum AnthropicSubscriptionAuthService {
    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let authorizeURL = URL(string: "https://claude.ai/oauth/authorize")!
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    private static let callbackPort: UInt16 = 53692
    private static let callbackPath = "/callback"
    private static let redirectURI = "http://localhost:53692/callback"
    private static let scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

    public static func signIn() async throws -> AnthropicSubscriptionCredentials {
        let session = try await startSignIn()

        let didOpen = await openAuthorizationURL(session.authorizationURL)
        guard didOpen else {
            throw AnthropicSubscriptionAuthError.browserOpenFailed
        }

        return try await session.waitForCredentials()
    }

    public static func openAuthorizationURL(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    public static func startSignIn() async throws -> AnthropicSubscriptionSignInSession {
        let flow = try authorizationFlow()
        let callbackServer = try await AnthropicSubscriptionCallbackServer(
            state: flow.state,
            port: callbackPort,
            path: callbackPath
        ).start()
        return AnthropicSubscriptionSignInSession(
            authorizationURL: flow.url,
            verifier: flow.verifier,
            callbackServer: callbackServer
        )
    }

    public static func refresh(
        credentials: AnthropicSubscriptionCredentials
    ) async throws -> AnthropicSubscriptionCredentials {
        let refreshedCredentials = try await refreshAccessToken(
            refreshToken: credentials.refreshToken
        )
        try saveCredentials(refreshedCredentials)
        return refreshedCredentials
    }

    public static func loadCredentials() throws -> AnthropicSubscriptionCredentials {
        if let environmentToken = ProcessInfo.processInfo.environment["ANTHROPIC_OAUTH_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? ProcessInfo.processInfo.environment["ANTHROPIC_ACCESS_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty {
            let refreshToken = ProcessInfo.processInfo.environment["ANTHROPIC_OAUTH_REFRESH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? ProcessInfo.processInfo.environment["ANTHROPIC_REFRESH_TOKEN"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? environmentToken
            return AnthropicSubscriptionCredentials(
                accessToken: environmentToken,
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                scope: ProcessInfo.processInfo.environment["ANTHROPIC_OAUTH_SCOPE"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty
            )
        }

        guard let credentials = AgentSettingsManifestStore.load()?.anthropicSubscriptionCredentials else {
            throw AnthropicSubscriptionAuthError.missingCredentials
        }
        guard !credentials.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AnthropicSubscriptionAuthError.invalidCredentials
        }
        return credentials
    }

    public static func loadValidCredentials() async throws -> AnthropicSubscriptionCredentials {
        let credentials = try loadCredentials()
        guard credentials.isExpiredOrNearlyExpired else {
            return credentials
        }
        return try await refresh(credentials: credentials)
    }

    public static func saveCredentials(_ credentials: AnthropicSubscriptionCredentials) throws {
        try AgentSettingsManifestStore.saveAnthropicSubscriptionCredentials(credentials)
    }

    public static func removeCredentials() {
        try? AgentSettingsManifestStore.saveAnthropicSubscriptionCredentials(nil)
    }

    private static func authorizationFlow() throws -> (
        verifier: String,
        state: String,
        url: URL
    ) {
        let verifier = try randomBase64URLString(byteCount: 32)
        let challenge = sha256Base64URL(verifier)
        // Anthropic's Claude Code OAuth flow uses the verifier as the state value.
        let state = verifier

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]

        guard let url = components.url else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }
        return (verifier, state, url)
    }

    public static func exchangeAuthorizationCode(
        code: String,
        state: String,
        verifier: String
    ) async throws -> AnthropicSubscriptionCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "state": state,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])
    }

    private static func refreshAccessToken(
        refreshToken: String
    ) async throws -> AnthropicSubscriptionCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken
        ])
    }

    private static func tokenRequest(
        parameters: [String: String]
    ) async throws -> AnthropicSubscriptionCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicSubscriptionAuthError.invalidTokenResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AnthropicSubscriptionAuthError.tokenExchangeFailed(
                status: httpResponse.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let accessToken = tokenResponse.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = tokenResponse.refreshToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty else {
            throw AnthropicSubscriptionAuthError.missingAccessToken
        }
        guard !refreshToken.isEmpty else {
            throw AnthropicSubscriptionAuthError.missingRefreshToken
        }
        guard tokenResponse.expiresIn > 0 else {
            throw AnthropicSubscriptionAuthError.invalidTokenResponse
        }

        let expirationInterval = max(tokenResponse.expiresIn - 300, 60)
        return AnthropicSubscriptionCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expirationInterval)),
            scope: tokenResponse.scope?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        )
    }

    private static func randomBase64URLString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw AnthropicSubscriptionAuthError.randomBytesFailed(status)
        }
        return Data(bytes).base64URLEncodedString()
    }

    private static func sha256Base64URL(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let scope: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

private struct AnthropicSubscriptionAuthorizationResult: Sendable {
    let code: String
    let state: String
}

private final class AnthropicSubscriptionCallbackServer: @unchecked Sendable {
    private let state: String
    private let port: UInt16
    private let path: String
    private let queue = DispatchQueue(label: "MLXCoder.AnthropicSubscriptionCallback")
    private let lock = OSAllocatedUnfairLock()
    private var listener: NWListener?
    private var waitContinuation: CheckedContinuation<AnthropicSubscriptionAuthorizationResult, Error>?
    private var pendingResult: Result<AnthropicSubscriptionAuthorizationResult, Error>?
    private var isStopped = false

    init(state: String, port: UInt16, path: String) {
        self.state = state
        self.port = port
        self.path = path
    }

    func start() async throws -> AnthropicSubscriptionCallbackServer {
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort) else {
            throw AnthropicSubscriptionAuthError.callbackServerUnavailable
        }

        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        do {
            try await startListening(listener)
        } catch {
            listener.cancel()
            self.listener = nil
            throw AnthropicSubscriptionAuthError.callbackServerUnavailable
        }

        return self
    }

    func submitAuthorizationInput(_ input: String) throws {
        let result = try authorizationResult(fromAuthorizationInput: input)
        complete(.success(result))
    }

    private func authorizationResult(
        fromAuthorizationInput input: String
    ) throws -> AnthropicSubscriptionAuthorizationResult {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }

        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "code" }) == true {
            return try authorizationResult(from: components, requireState: false)
        }

        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                let returnedState = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard returnedState == state else {
                    throw AnthropicSubscriptionAuthError.stateMismatch
                }
                let code = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else {
                    throw AnthropicSubscriptionAuthError.missingAuthorizationCode
                }
                return AnthropicSubscriptionAuthorizationResult(
                    code: code,
                    state: returnedState
                )
            }
        }

        if value.contains("code=") {
            let query = value.hasPrefix("?") ? String(value.dropFirst()) : value
            if let components = URLComponents(string: "http://localhost\(path)?\(query)"),
               components.queryItems?.contains(where: { $0.name == "code" }) == true {
                return try authorizationResult(from: components, requireState: false)
            }
        }

        return AnthropicSubscriptionAuthorizationResult(code: value, state: state)
    }

    private func authorizationResult(
        from components: URLComponents,
        requireState: Bool
    ) throws -> AnthropicSubscriptionAuthorizationResult {
        let queryItems = components.queryItems ?? []
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let returnedState {
            guard returnedState == state else {
                throw AnthropicSubscriptionAuthError.stateMismatch
            }
        } else if requireState {
            throw AnthropicSubscriptionAuthError.missingOAuthState
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            throw AnthropicSubscriptionAuthError.missingAuthorizationCode
        }
        return AnthropicSubscriptionAuthorizationResult(
            code: code,
            state: returnedState ?? state
        )
    }

    private func startListening(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let startState = AnthropicSubscriptionCallbackStartState(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    startState.resume(with: .success(()))
                case let .failed(error):
                    startState.resume(with: .failure(error))
                case .cancelled:
                    startState.resume(with: .failure(AnthropicSubscriptionAuthError.callbackCancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForAuthorizationResult() async throws -> AnthropicSubscriptionAuthorizationResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pendingResult {
                self.pendingResult = nil
                lock.unlock()
                continuation.resume(with: pendingResult)
                return
            }
            if isStopped {
                lock.unlock()
                continuation.resume(throwing: AnthropicSubscriptionAuthError.callbackCancelled)
                return
            }
            waitContinuation = continuation
            lock.unlock()
        }
    }

    func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let continuation = waitContinuation
        waitContinuation = nil
        lock.unlock()

        listener?.cancel()
        listener = nil
        continuation?.resume(throwing: AnthropicSubscriptionAuthError.callbackCancelled)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                self.sendResponse(
                    statusCode: 400,
                    body: Self.errorHTML("Unable to read sign-in callback."),
                    on: connection
                )
                self.complete(.failure(AnthropicSubscriptionAuthError.callbackRequestInvalid))
                return
            }

            do {
                guard let callbackPath = self.callbackPath(from: data),
                      callbackPath == self.path else {
                    self.sendResponse(
                        statusCode: 404,
                        body: Self.errorHTML("This callback does not belong to MLXCoder."),
                        on: connection
                    )
                    return
                }
                let result = try self.authorizationResult(from: data)
                self.sendResponse(
                    statusCode: 200,
                    body: Self.successHTML(),
                    on: connection
                )
                self.complete(.success(result))
            } catch {
                self.sendResponse(
                    statusCode: 400,
                    body: Self.errorHTML(error.localizedDescription),
                    on: connection
                )
                self.complete(.failure(error))
            }
        }
    }

    private func callbackPath(from data: Data?) -> String? {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2,
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            return nil
        }
        return components.path
    }

    private func authorizationResult(from data: Data?) throws -> AnthropicSubscriptionAuthorizationResult {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }
        guard components.path == path else {
            throw AnthropicSubscriptionAuthError.callbackRequestInvalid
        }
        return try authorizationResult(from: components, requireState: true)
    }

    private func complete(_ result: Result<AnthropicSubscriptionAuthorizationResult, Error>) {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        let continuation = waitContinuation
        waitContinuation = nil
        if continuation == nil {
            pendingResult = result
        }
        lock.unlock()

        listener?.cancel()
        listener = nil
        continuation?.resume(with: result)
    }

    private func sendResponse(
        statusCode: Int,
        body: String,
        on connection: NWConnection
    ) {
        let reason = statusCode == 200 ? "OK" : "Bad Request"
        let bodyData = Data(body.utf8)
        var response = Data(
            """
            HTTP/1.1 \(statusCode) \(reason)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(bodyData.count)\r
            Connection: close\r
            \r
            """.utf8
        )
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func successHTML() -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>MLXCoder</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px;">
        <h1>Anthropic connected</h1>
        <p>You can close this window and return to MLXCoder.</p>
        </body>
        </html>
        """
    }

    private static func errorHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>MLXCoder</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px;">
        <h1>Sign-in failed</h1>
        <p>\(message)</p>
        </body>
        </html>
        """
    }
}

private final class AnthropicSubscriptionCallbackStartState: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
        }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
