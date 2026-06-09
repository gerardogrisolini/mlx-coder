//
//  MCPBrowserOAuthCallbackServer.swift
//  SwiftMLX
//
//  Created by Gerardo Grisolini on 12/04/26.
//

import Foundation
#if os(macOS)
import Network

public nonisolated final class MCPBrowserOAuthCallbackServer: @unchecked Sendable {
    public let redirectURL: URL
    public let serviceName: String
    public let queue = DispatchQueue(label: "mlx-coder.MCPBrowserOAuthCallbackServer")
    public let listener: NWListener
    public var readinessContinuation: CheckedContinuation<Void, Error>?
    public var callbackContinuation: CheckedContinuation<MCPOAuthCallback, Error>?
    public var didResumeReadiness = false
    public var didResumeCallback = false

    public init(redirectURL: URL, serviceName: String) throws {
        guard redirectURL.scheme == "http",
              let host = redirectURL.host,
              host == "127.0.0.1" || host == "localhost",
              let port = redirectURL.port,
              let listenerPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw MCPClientError.browserAuthenticationFailed(
                "The \(serviceName) browser sign-in callback URL is invalid."
            )
        }

        self.redirectURL = redirectURL
        self.serviceName = serviceName
        self.listener = try NWListener(using: .tcp, on: listenerPort)
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.readinessContinuation = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener.cancel()
            self.resumeReadinessIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "The \(self.serviceName) browser sign-in was interrupted."
                    )
                )
            )
        }
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> MCPOAuthCallback {
        try await withThrowingTaskGroup(of: MCPOAuthCallback.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.queue.async {
                        self.callbackContinuation = continuation
                    }
                }
            }

            group.addTask {
                let timeoutNanoseconds = UInt64(max(timeout, 1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MCPClientError.browserAuthenticationFailed(
                    "Timed out waiting for \(self.serviceName) sign-in in the browser."
                )
            }

            guard let callback = try await group.next() else {
                throw MCPClientError.invalidResponse
            }

            group.cancelAll()
            return callback
        }
    }

    public func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            resumeReadinessIfNeeded(with: .success(()))
        case let .failed(error):
            let wrappedError = MCPClientError.browserAuthenticationFailed(
                "mlx-coder could not start the local \(serviceName) sign-in callback server. \(error.localizedDescription)"
            )
            resumeReadinessIfNeeded(with: .failure(wrappedError))
            resumeCallbackIfNeeded(with: .failure(wrappedError))
        case .cancelled:
            let cancellationError = MCPClientError.browserAuthenticationFailed(
                "The \(serviceName) browser sign-in was interrupted."
            )
            resumeReadinessIfNeeded(with: .failure(cancellationError))
            resumeCallbackIfNeeded(with: .failure(cancellationError))
        default:
            break
        }
    }

    public func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            self?.handleReceivedRequest(data: data, error: error, connection: connection)
        }
    }

    public func handleReceivedRequest(
        data: Data?,
        error: NWError?,
        connection: NWConnection
    ) {
        if let error {
            sendResponse(
                statusCode: 500,
                title: "\(serviceName) Sign-In Failed",
                message: error.localizedDescription,
                on: connection
            )
            resumeCallbackIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "The \(serviceName) browser sign-in callback failed. \(error.localizedDescription)"
                    )
                )
            )
            return
        }

        guard let data,
              let requestText = String(data: data, encoding: .utf8),
              let firstLine = requestText.components(separatedBy: .newlines).first else {
            sendResponse(
                statusCode: 400,
                title: "Invalid Callback",
                message: "mlx-coder received an invalid \(serviceName) sign-in callback.",
                on: connection
            )
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(
                statusCode: 400,
                title: "Invalid Callback",
                message: "mlx-coder received an invalid \(serviceName) sign-in callback.",
                on: connection
            )
            return
        }

        let requestTarget = String(parts[1])
        guard let callbackURL = URL(string: "http://\(redirectURL.host ?? "127.0.0.1")\(requestTarget)"),
              callbackURL.path == redirectURL.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            sendResponse(
                statusCode: 404,
                title: "Unknown Callback",
                message: "This browser callback does not belong to mlx-coder.",
                on: connection
            )
            return
        }

        let queryItems = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
            uniquingKeysWith: { current, _ in current }
        )

        if let oauthError = queryItems["error"], !oauthError.isEmpty {
            let description = queryItems["error_description"] ?? oauthError
            sendResponse(
                statusCode: 400,
                title: "\(serviceName) Sign-In Failed",
                message: description,
                on: connection
            )
            resumeCallbackIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "\(serviceName) sign-in was not completed. \(description)"
                    )
                )
            )
            return
        }

        guard let code = queryItems["code"], !code.isEmpty,
              let state = queryItems["state"], !state.isEmpty else {
            sendResponse(
                statusCode: 400,
                title: "\(serviceName) Sign-In Failed",
                message: "The \(serviceName) sign-in callback did not include the expected authorization code.",
                on: connection
            )
            resumeCallbackIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "The \(serviceName) sign-in callback did not include the expected authorization code."
                    )
                )
            )
            return
        }

        sendResponse(
            statusCode: 200,
            title: "\(serviceName) Connected",
            message: "mlx-coder has completed \(serviceName) sign-in. You can close this browser tab and return to the app.",
            on: connection
        )
        resumeCallbackIfNeeded(with: .success(MCPOAuthCallback(code: code, state: state)))
    }

    public func sendResponse(
        statusCode: Int,
        title: String,
        message: String,
        on connection: NWConnection
    ) {
        let responseBody = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 32px;">
        <h1>\(title)</h1>
        <p>\(message)</p>
        </body>
        </html>
        """
        let payload = """
        HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))
        Content-Type: text/html; charset=utf-8
        Content-Length: \(responseBody.utf8.count)
        Connection: close

        \(responseBody)
        """

        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    public func resumeReadinessIfNeeded(with result: Result<Void, Error>) {
        guard !didResumeReadiness, let readinessContinuation else {
            return
        }

        didResumeReadiness = true
        self.readinessContinuation = nil
        switch result {
        case .success:
            readinessContinuation.resume()
        case let .failure(error):
            readinessContinuation.resume(throwing: error)
        }
    }

    public func resumeCallbackIfNeeded(with result: Result<MCPOAuthCallback, Error>) {
        guard !didResumeCallback, let callbackContinuation else {
            return
        }

        didResumeCallback = true
        self.callbackContinuation = nil
        switch result {
        case let .success(callback):
            callbackContinuation.resume(returning: callback)
        case let .failure(error):
            callbackContinuation.resume(throwing: error)
        }
    }

    public static func reasonPhrase(for statusCode: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }
}
#endif
