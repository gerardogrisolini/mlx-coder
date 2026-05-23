//
//  MCPClient+LocalTransport.swift
//  SwiftMLX
//
//  Created by Gerardo Grisolini on 12/04/26.
//

#if canImport(Darwin)
import Darwin
#endif
import Foundation

#if os(macOS)

public extension MCPClient {
    public func connect() async throws {
        if let httpTransport {
            try await httpTransport.connect()
            return
        }

        if let terminalBridgeError {
            throw terminalBridgeError
        }

        guard process == nil else {
            return
        }

        log(buildMarker)
        log("Launching MCP bridge: \(configuration.executablePath) \(configuration.arguments.joined(separator: " "))")
        if !configuration.environment.isEmpty {
            log("Bridge environment: \(configuration.environment)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.executablePath)
        process.arguments = configuration.arguments

        let environment = configuration.environment
        let mcpEnvironment = environment.filter { key, _ in
            key.hasPrefix("MCP_XCODE")
        }
        process.environment = environment
        log("Resolved bridge environment: \(mcpEnvironment)")

        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
        process.terminationHandler = { [weak self] terminatedProcess in
            Task {
                await self?.handleProcessTermination(terminatedProcess)
            }
        }

        try process.run()

        self.process = process
        inputHandle = standardInput.fileHandleForWriting

        signal(SIGPIPE, SIG_IGN)
        prepareStdoutTracingFiles()

        let outputHandle = standardOutput.fileHandleForReading
        readLoopTask = Task.detached { [self] in
            await Self.readLoop(from: outputHandle, client: self)
        }

        let errorHandle = standardError.fileHandleForReading
        errorLoopTask = Task.detached { [self] in
            await Self.errorLoop(from: errorHandle, client: self)
        }

        let initializeParams = MCPInitializeParams(
            protocolVersion: configuration.preferredProtocolVersion,
            capabilities: MCPClientCapabilities(),
            clientInfo: MCPClientInfo(name: "mlx-coder", version: "0.1")
        )

        if configuration.usesMCPBridgeExecutable {
            let initializeRequestID = nextRequestID
            nextRequestID += 1

            let initializeRequest = MCPRequest(
                jsonrpc: "2.0",
                id: .int(initializeRequestID),
                method: "initialize",
                params: initializeParams
            )
            let initializePayload = try JSONEncoder().encode(initializeRequest)
            let initializedNotification = MCPNotification(
                jsonrpc: "2.0",
                method: "notifications/initialized",
                params: JSONValue.object([:])
            )
            let initializedPayload = try JSONEncoder().encode(initializedNotification)

            log("Sending initialize request (mcpbridge optimistic handshake)")
            log(
                "Request \(initializeRequestID) -> initialize: " +
                (String(data: initializePayload, encoding: .utf8) ?? "<non-utf8>")
            )
            _ = try await withCheckedThrowingContinuation(isolation: self) { continuation in
                pendingResponses[initializeRequestID] = continuation

                do {
                    try write(initializePayload)
                    log("Sending initialized notification early for mcpbridge")
                    try write(initializedPayload)
                } catch {
                    pendingResponses.removeValue(forKey: initializeRequestID)
                    continuation.resume(throwing: error)
                }
            }
            importantLog("Initialize completed successfully for request \(initializeRequestID).")
            log("MCP bridge connected successfully")
            return
        }

        log("Sending initialize request")
        _ = try await request(
            method: "initialize",
            params: initializeParams
        )

        log("Sending initialized notification")
        try await notify(method: "notifications/initialized", params: JSONValue.object([:]))

        log("MCP bridge connected successfully")
    }

    public func disconnect() async {
        if let httpTransport {
            await httpTransport.disconnect()
            return
        }

        readLoopTask?.cancel()
        readLoopTask = nil
        errorLoopTask?.cancel()
        errorLoopTask = nil

        inputHandle?.closeFile()
        inputHandle = nil

        if let process {
            if process.isRunning {
                process.terminate()
            }
            self.process = nil
        }

        resumeAllPending(with: MCPClientError.connectionClosed)
        buffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        terminalBridgeError = nil
        stdoutChunkTraceURLs.removeAll(keepingCapacity: false)
        stdoutReassembledBufferURLs.removeAll(keepingCapacity: false)
        lastReassembledBufferSize = -1
    }

    public func listTools() async throws -> MCPListToolsResult {
        if let httpTransport {
            return try await httpTransport.listTools()
        }

        try await connect()
        log("Starting tools/list request")
        let response = try await request(method: "tools/list", params: JSONValue.object([:]))
        return try response.decode(MCPListToolsResult.self)
    }

    public func callTool(named name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        if let httpTransport {
            return try await httpTransport.callTool(named: name, arguments: arguments)
        }

        try await connect()
        return try await request(
            method: "tools/call",
            params: JSONValue.object([
                "name": .string(name),
                "arguments": .object(arguments)
            ])
        )
    }

    private func request<Params: Encodable>(
        method: String,
        params: Params,
        onRequestWritten: (@Sendable () -> Void)? = nil
    ) async throws -> JSONValue {
        if let terminalBridgeError {
            throw terminalBridgeError
        }

        let requestID = nextRequestID
        nextRequestID += 1

        let request = MCPRequest(
            jsonrpc: "2.0",
            id: .int(requestID),
            method: method,
            params: params
        )

        let payload = try JSONEncoder().encode(request)
        log("Request \(requestID) -> \(method): \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")

        return try await withCheckedThrowingContinuation(isolation: self) { continuation in
            pendingResponses[requestID] = continuation

            do {
                try write(payload)
                onRequestWritten?()
            } catch {
                pendingResponses.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func notify(method: String) async throws {
        let notification = MCPNotificationWithoutParams(
            jsonrpc: "2.0",
            method: method
        )

        let payload = try JSONEncoder().encode(notification)
        log("Notification -> \(method): \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")
        try write(payload)
    }

    private func notify<Params: Encodable>(method: String, params: Params) async throws {
        let notification = MCPNotification(
            jsonrpc: "2.0",
            method: method,
            params: params
        )

        let payload = try JSONEncoder().encode(notification)
        log("Notification -> \(method): \(String(data: payload, encoding: .utf8) ?? "<non-utf8>")")
        try write(payload)
    }

    private func write(_ payload: Data) throws {
        if let terminalBridgeError {
            throw terminalBridgeError
        }

        guard let inputHandle else {
            throw MCPClientError.connectionClosed
        }

        guard let process else {
            throw MCPClientError.connectionClosed
        }

        guard process.isRunning else {
            throw exitError(for: process)
        }

        let framedPayload = MCPTransportCodec.frame(payload)
        do {
            try Self.writeAll(framedPayload, to: inputHandle.fileDescriptor)
        } catch {
            log("Write failed: \(error.localizedDescription)")
            throw exitError(for: process)
        }
    }

    private nonisolated static func writeAll(_ payload: Data, to fileDescriptor: Int32) throws {
        try payload.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }

            var totalBytesWritten = 0
            while totalBytesWritten < rawBuffer.count {
                let remainingByteCount = rawBuffer.count - totalBytesWritten
                let nextBaseAddress = baseAddress.advanced(by: totalBytesWritten)
                let bytesWritten = Darwin.write(fileDescriptor, nextBaseAddress, remainingByteCount)

                if bytesWritten > 0 {
                    totalBytesWritten += bytesWritten
                    continue
                }

                if bytesWritten == -1, errno == EINTR {
                    continue
                }

                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
}
#endif
