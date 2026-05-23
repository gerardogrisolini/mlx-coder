//
//  ChatGPTSubscriptionAuthService.swift
//  MLXCoder
//
//  Created by Codex on 24/05/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import AppKit
import CryptoKit
import Network
import Security
#endif

public enum ChatGPTSubscriptionAuthError: LocalizedError {
    case unsupportedPlatform
    case callbackServerUnavailable
    case callbackCancelled
    case callbackRequestInvalid
    case stateMismatch
    case missingAuthorizationCode
    case tokenExchangeFailed(status: Int, body: String)
    case invalidTokenResponse
    case browserOpenFailed
    case randomBytesFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "ChatGPT Subscription browser sign-in is available on macOS."
        case .callbackServerUnavailable:
            return "Unable to start the local ChatGPT sign-in callback server."
        case .callbackCancelled:
            return "ChatGPT sign-in was cancelled."
        case .callbackRequestInvalid:
            return "ChatGPT sign-in callback was invalid."
        case .stateMismatch:
            return "ChatGPT sign-in state did not match."
        case .missingAuthorizationCode:
            return "ChatGPT sign-in did not return an authorization code."
        case let .tokenExchangeFailed(status, body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT sign-in token exchange failed with HTTP \(status)."
            }
            return "ChatGPT sign-in token exchange failed with HTTP \(status): \(detail)"
        case .invalidTokenResponse:
            return "ChatGPT sign-in returned an invalid token response."
        case .browserOpenFailed:
            return "Unable to open the ChatGPT sign-in page."
        case let .randomBytesFailed(status):
            return "Unable to create ChatGPT sign-in verifier (\(status))."
        }
    }
}

#if os(macOS)
public final class ChatGPTSubscriptionSignInSession: @unchecked Sendable {
    public let authorizationURL: URL

    private let verifier: String
    private let callbackServer: ChatGPTSubscriptionCallbackServer

    fileprivate init(
        authorizationURL: URL,
        verifier: String,
        callbackServer: ChatGPTSubscriptionCallbackServer
    ) {
        self.authorizationURL = authorizationURL
        self.verifier = verifier
        self.callbackServer = callbackServer
    }

    public func waitForCredentials() async throws -> CodexAgentCredentials {
        defer {
            callbackServer.stop()
        }

        let code = try await callbackServer.waitForCode()
        let credentials = try await ChatGPTSubscriptionAuthService.exchangeAuthorizationCode(
            code: code,
            verifier: verifier
        )
        try CodexAgentModel.saveCredentials(credentials)
        return credentials
    }

    public func submitAuthorizationInput(_ input: String) throws {
        try callbackServer.submitAuthorizationInput(input)
    }

    public func cancel() {
        callbackServer.stop()
    }
}

public enum ChatGPTSubscriptionAuthService {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let scope = "openid profile email offline_access"
    private static let originator = "mlx-coder"

    public static func signIn() async throws -> CodexAgentCredentials {
        let session = try await startSignIn()

        let didOpen = await openAuthorizationURL(session.authorizationURL)
        guard didOpen else {
            throw ChatGPTSubscriptionAuthError.browserOpenFailed
        }

        return try await session.waitForCredentials()
    }

    public static func openAuthorizationURL(_ url: URL) async -> Bool {
        await MainActor.run {
            NSWorkspace.shared.open(url)
        }
    }

    public static func startSignIn() async throws -> ChatGPTSubscriptionSignInSession {
        let flow = try authorizationFlow()
        let callbackServer = await ChatGPTSubscriptionCallbackServer(
            state: flow.state
        ).start()
        return ChatGPTSubscriptionSignInSession(
            authorizationURL: flow.url,
            verifier: flow.verifier,
            callbackServer: callbackServer
        )
    }

    public static func refresh(credentials: CodexAgentCredentials) async throws -> CodexAgentCredentials {
        let refreshedCredentials = try await refreshAccessToken(
            refreshToken: credentials.refreshToken
        )
        try CodexAgentModel.saveCredentials(refreshedCredentials)
        return refreshedCredentials
    }

    private static func authorizationFlow() throws -> (
        verifier: String,
        state: String,
        url: URL
    ) {
        let verifier = try randomBase64URLString(byteCount: 32)
        let challenge = sha256Base64URL(verifier)
        let state = try randomBase64URLString(byteCount: 16)

        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: originator)
        ]

        guard let url = components.url else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }
        return (verifier, state, url)
    }

    public static func exchangeAuthorizationCode(
        code: String,
        verifier: String
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI
        ])
    }

    private static func refreshAccessToken(
        refreshToken: String
    ) async throws -> CodexAgentCredentials {
        try await tokenRequest(parameters: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
    }

    private static func tokenRequest(
        parameters: [String: String]
    ) async throws -> CodexAgentCredentials {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.httpBody = formURLEncodedBody(parameters)
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatGPTSubscriptionAuthError.invalidTokenResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ChatGPTSubscriptionAuthError.tokenExchangeFailed(
                status: httpResponse.statusCode,
                body: String(decoding: data, as: UTF8.self)
            )
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        let accessToken = tokenResponse.accessToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = tokenResponse.refreshToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessToken.isEmpty,
              !refreshToken.isEmpty,
              tokenResponse.expiresIn > 0 else {
            throw ChatGPTSubscriptionAuthError.invalidTokenResponse
        }

        return CodexAgentCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            accountID: try CodexAgentModel.chatGPTAccountID(from: accessToken)
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

    private static func randomBase64URLString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw ChatGPTSubscriptionAuthError.randomBytesFailed(status)
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

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private final class ChatGPTSubscriptionCallbackServer: @unchecked Sendable {
    private let state: String
    private let queue = DispatchQueue(label: "MLXCoder.ChatGPTSubscriptionCallback")
    private let lock = NSLock()
    private var listener: NWListener?
    private var waitContinuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var isStopped = false

    init(state: String) {
        self.state = state
    }

    func start() async -> ChatGPTSubscriptionCallbackServer {
        guard let listener = try? NWListener(using: .tcp, on: 1455) else {
            return self
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
        }

        return self
    }

    func submitAuthorizationInput(_ input: String) throws {
        let code = try authorizationCode(fromAuthorizationInput: input)
        complete(.success(code))
    }

    private func authorizationCode(fromAuthorizationInput input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }

        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "code" }) == true {
            return try authorizationCode(from: components, requireState: false)
        }

        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                guard parts[1] == state else {
                    throw ChatGPTSubscriptionAuthError.stateMismatch
                }
                let code = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else {
                    throw ChatGPTSubscriptionAuthError.missingAuthorizationCode
                }
                return code
            }
        }

        if value.contains("code=") {
            let query = value.hasPrefix("?") ? String(value.dropFirst()) : value
            if let components = URLComponents(string: "http://localhost/auth/callback?\(query)"),
               components.queryItems?.contains(where: { $0.name == "code" }) == true {
                return try authorizationCode(from: components, requireState: false)
            }
        }

        return value
    }

    private func authorizationCode(
        from components: URLComponents,
        requireState: Bool
    ) throws -> String {
        let queryItems = components.queryItems ?? []
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        if let returnedState {
            guard returnedState == state else {
                throw ChatGPTSubscriptionAuthError.stateMismatch
            }
        } else if requireState {
            throw ChatGPTSubscriptionAuthError.stateMismatch
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            throw ChatGPTSubscriptionAuthError.missingAuthorizationCode
        }
        return code
    }

    private func startListening(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let startState = CallbackStartState(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    startState.resume(with: .success(()))
                case let .failed(error):
                    startState.resume(with: .failure(error))
                case .cancelled:
                    startState.resume(with: .failure(ChatGPTSubscriptionAuthError.callbackCancelled))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
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
                continuation.resume(throwing: ChatGPTSubscriptionAuthError.callbackCancelled)
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
        continuation?.resume(throwing: ChatGPTSubscriptionAuthError.callbackCancelled)
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
                self.complete(.failure(ChatGPTSubscriptionAuthError.callbackRequestInvalid))
                return
            }

            do {
                guard let path = self.callbackPath(from: data),
                      path == "/auth/callback" else {
                    self.sendResponse(
                        statusCode: 404,
                        body: Self.errorHTML("This callback does not belong to MLXCoder."),
                        on: connection
                    )
                    return
                }
                let code = try self.authorizationCode(from: data)
                self.sendResponse(
                    statusCode: 200,
                    body: Self.successHTML(),
                    on: connection
                )
                self.complete(.success(code))
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

    private func authorizationCode(from data: Data?) throws -> String {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\r\n").first else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }
        guard components.path == "/auth/callback" else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }
        return try authorizationCode(from: components, requireState: true)
    }

    private func complete(_ result: Result<String, Error>) {
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
        <h1>ChatGPT connected</h1>
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

private final class CallbackStartState: @unchecked Sendable {
    private let lock = NSLock()
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
