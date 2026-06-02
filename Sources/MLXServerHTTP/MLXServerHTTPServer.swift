//
//  MLXServerHTTPServer.swift
//  mlx-server
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import MLXLMCommon
import MLXServerCore
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
@preconcurrency import NIOSSL

public struct MLXServerHTTPTransportConfiguration: Sendable {
    public var tlsCertificatePath: String?
    public var tlsPrivateKeyPath: String?
    public var http2PriorKnowledge: Bool

    public init(
        tlsCertificatePath: String? = nil,
        tlsPrivateKeyPath: String? = nil,
        http2PriorKnowledge: Bool = false
    ) {
        self.tlsCertificatePath = tlsCertificatePath
        self.tlsPrivateKeyPath = tlsPrivateKeyPath
        self.http2PriorKnowledge = http2PriorKnowledge
    }

    public var usesTLS: Bool {
        tlsCertificatePath != nil || tlsPrivateKeyPath != nil
    }
}

public struct MLXServerHTTPCustomRequest: Sendable {
    public let method: String
    public let path: String
    public let queryItems: [String: String]
    public let headers: [String: String]
    public let body: Data
}

public enum MLXServerHTTPCustomResponseStatus: Sendable {
    case ok
    case badRequest
    case notFound
    case internalServerError
}

public struct MLXServerHTTPCustomResponse: Sendable {
    public let status: MLXServerHTTPCustomResponseStatus
    public let body: [String: String]

    public init(
        status: MLXServerHTTPCustomResponseStatus = .ok,
        body: [String: String] = ["status": "ok"]
    ) {
        self.status = status
        self.body = body
    }

    public static func ok(_ body: [String: String] = ["status": "ok"]) -> Self {
        Self(status: .ok, body: body)
    }

    public static func badRequest(_ message: String) -> Self {
        Self(status: .badRequest, body: ["error": message])
    }
}

public typealias MLXServerHTTPCustomRouteHandler = @Sendable (
    MLXServerHTTPCustomRequest
) async throws -> MLXServerHTTPCustomResponse?

public final class MLXServerHTTPServer {
    private let configuration: MLXServerConfiguration
    private let transport: MLXServerHTTPTransportConfiguration
    private let application: MLXServerHTTPApplication
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(
        configuration: MLXServerConfiguration,
        runtime: any MLXServerRuntimeGenerating,
        modelCatalog: MLXServerModelCatalog,
        kvCacheSettings: MLXServerKVCacheSettings = .init(),
        transport: MLXServerHTTPTransportConfiguration = .init(),
        apiKey: String? = nil,
        metricsLogger: MLXServerMetricsLogger? = nil,
        customRouteHandler: MLXServerHTTPCustomRouteHandler? = nil,
        eventLoopThreadCount: Int = MLXServerSettings.defaultWebServerThreadCount
    ) {
        self.configuration = configuration
        self.transport = transport
        self.application = MLXServerHTTPApplication(
            runtime: runtime,
            modelCatalog: modelCatalog,
            kvCacheSettings: kvCacheSettings.validated(),
            apiKey: apiKey?.trimmedNonEmpty,
            metricsLogger: metricsLogger,
            customRouteHandler: customRouteHandler
        )
        self.group = MultiThreadedEventLoopGroup(
            numberOfThreads: max(1, eventLoopThreadCount)
        )
    }

    public func start() throws {
        let sslContext = try makeSSLContext()
        let transport = transport
        let application = application
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                Self.configure(
                    channel: channel,
                    sslContext: sslContext,
                    transport: transport,
                    application: application
                )
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)

        let channel = try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
        self.channel = channel

        let scheme = transport.usesTLS ? "https" : "http"
        let protocols = transport.usesTLS
            ? "http/1.1, h2"
            : (transport.http2PriorKnowledge ? "h2 prior-knowledge" : "http/1.1")
        print("mlx-server listening on \(scheme)://\(configuration.host):\(configuration.port) (\(protocols))")
        fflush(stdout)
    }

    public var boundPort: Int? {
        channel?.localAddress?.port
    }

    public func stop() throws {
        try channel?.close().wait()
        try group.syncShutdownGracefully()
    }

    private func makeSSLContext() throws -> NIOSSLContext? {
        switch (transport.tlsCertificatePath, transport.tlsPrivateKeyPath) {
        case (.none, .none):
            return nil
        case (.some(let certificatePath), .some(let privateKeyPath)):
            var tlsConfiguration = TLSConfiguration.makeServerConfiguration(
                certificateChain: try NIOSSLCertificate.fromPEMFile(certificatePath).map { .certificate($0) },
                privateKey: .privateKey(try NIOSSLPrivateKey(file: privateKeyPath, format: .pem))
            )
            tlsConfiguration.applicationProtocols = NIOHTTP2SupportedALPNProtocols
            return try NIOSSLContext(configuration: tlsConfiguration)
        default:
            throw MLXServerHTTPError.incompleteTLSConfiguration
        }
    }

    private static func configure(
        channel: Channel,
        sslContext: NIOSSLContext?,
        transport: MLXServerHTTPTransportConfiguration,
        application: MLXServerHTTPApplication
    ) -> EventLoopFuture<Void> {
        if let sslContext {
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
            }.flatMap {
                channel.configureCommonHTTPServerPipeline { streamChannel in
                    Self.addApplicationHandlers(to: streamChannel, application: application)
                }
            }
        }

        if transport.http2PriorKnowledge {
            return channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
                streamChannel.eventLoop.makeCompletedFuture {
                    let sync = streamChannel.pipeline.syncOperations
                    try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                    try sync.addHandler(MLXServerNIOHTTPHandler(application: application))
                    try sync.addHandler(MLXServerNIOErrorHandler())
                }
            }.flatMap { _ in
                channel.pipeline.addHandler(MLXServerNIOErrorHandler())
            }
        }

        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            Self.addApplicationHandlers(to: channel, application: application)
        }
    }

    private static func addApplicationHandlers(
        to channel: Channel,
        application: MLXServerHTTPApplication
    ) -> EventLoopFuture<Void> {
        channel.eventLoop.makeCompletedFuture {
            let sync = channel.pipeline.syncOperations
            try sync.addHandler(MLXServerNIOHTTPHandler(application: application))
            try sync.addHandler(MLXServerNIOErrorHandler())
        }
    }
}

private struct MLXServerHTTPApplication: Sendable {
    let runtime: any MLXServerRuntimeGenerating
    let modelCatalog: MLXServerModelCatalog
    let kvCacheSettings: MLXServerKVCacheSettings
    let apiKey: String?
    let metricsLogger: MLXServerMetricsLogger?
    let customRouteHandler: MLXServerHTTPCustomRouteHandler?
}

private extension MLXServerHTTPApplication {
    func respond(to request: HTTPRequest, writer: MLXServerNIOResponseWriter) async {
        do {
            guard isAuthorized(request) else {
                try await writer.sendJSON(
                    ErrorResponse(error: .init(message: "Missing or invalid API key.", type: "authentication_error")),
                    status: .unauthorized
                )
                return
            }

            if let customResponse = try await customRouteHandler?(MLXServerHTTPCustomRequest(request)) {
                try await writer.sendJSON(customResponse.body, status: customResponse.status.httpStatus)
                return
            }

            switch (request.method, request.path) {
            case ("GET", "/health"):
                try await writer.sendJSON(["status": "ok"])
            case ("GET", "/v1/models"):
                try await writer.sendJSON(ModelsResponse(models: modelCatalog.models))
            case ("POST", "/v1/chat/completions"):
                try await respondToChatCompletion(request, writer: writer)
            case ("POST", "/v1/responses"):
                try await respondToResponses(request, writer: writer)
            case ("POST", "/v1/messages"):
                try await respondToAnthropicMessages(request, writer: writer)
            default:
                try await writer.sendJSON(
                    ErrorResponse(error: .init(message: "Route not found", type: "not_found")),
                    status: .notFound
                )
            }
        } catch let error as DecodingError {
            logRequestError(error, request: request, status: .badRequest)
            await sendError(error, status: .badRequest, writer: writer)
        } catch let error as MLXServerModelsManifestError {
            logRequestError(error, request: request, status: .badRequest)
            await sendError(error, status: .badRequest, writer: writer)
        } catch let error as MLXServerRuntimeError {
            logRequestError(error, request: request, status: .badRequest)
            await sendError(error, status: .badRequest, writer: writer)
        } catch {
            logRequestError(error, request: request, status: .internalServerError)
            await sendError(error, status: .internalServerError, writer: writer)
        }
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let apiKey else {
            return true
        }
        guard request.path != "/health" else {
            return true
        }
        if let bearerToken = request.bearerToken,
           secureCompare(bearerToken, apiKey) {
            return true
        }
        if let rawAuthorization = request.headers["authorization"]?.trimmedNonEmpty,
           secureCompare(rawAuthorization, apiKey) {
            return true
        }
        if let xAPIKey = request.headers["x-api-key"]?.trimmedNonEmpty,
           secureCompare(xAPIKey, apiKey) {
            return true
        }
        return false
    }

    private func respondToChatCompletion(_ request: HTTPRequest, writer: MLXServerNIOResponseWriter) async throws {
        let body = try request.decode(OpenAIChatCompletionRequest.self)
        let model = try modelCatalog.resolve(id: body.model)
        let thinkingSelection = body.thinkingSelection(for: model.thinking)
        let generationRequest = MLXServerGenerationRequest(
            model: model,
            messages: body.serverMessages,
            parameters: body.generateParameters(
                defaults: model.generationDefaults,
                kvCacheSettings: kvCacheSettings
            ),
            tools: body.toolSpecs,
            additionalContext: model.thinking.additionalContext(for: thinkingSelection),
            retainsReasoningInHistory: thinkingSelection.isEnabled && model.thinking.supportsPreserveThinking
        )

        if body.stream == true {
            try await streamChatCompletion(request: generationRequest, model: model, writer: writer)
            return
        }

        let startedAt = Date()
        let output = try await runtime.generateChatSessionText(request: generationRequest)
        try await writer.sendJSON(
            ChatCompletionResponse(
                model: model.id,
                text: output.text,
                toolCalls: output.toolCalls,
                emitsThinking: thinkingSelection.isEnabled,
                info: output.info
            )
        )
        await logMetrics(
            endpoint: "chat_completions",
            protocolName: writer.protocolName,
            runtimeKind: generationRequest.runtimeKind,
            model: model.id,
            streamed: false,
            startedAt: startedAt,
            info: output.info
        )
    }

    private func streamChatCompletion(
        request: MLXServerGenerationRequest,
        model: MLXServerModelDescriptor,
        writer: MLXServerNIOResponseWriter
    ) async throws {
        let id = "chatcmpl-\(UUID().uuidString)"
        let stream = try await runtime.generateChatSession(request: request)
        try await writer.sendSSEHeaders()

        let startedAt = Date()
        var completionInfo: GenerateCompletionInfo?
        var chunkWriter = ChatCompletionStreamingContentWriter(
            writer: writer,
            id: id,
            model: model.id,
            emitsThinking: request.emitsThinking
        )
        do {
            try await writer.sendSSE(data: ChatCompletionChunk.role(id: id, model: model.id))
            for await event in stream {
                switch event {
                case .chunk(let chunk):
                    try await chunkWriter.write(chunk)
                case .info(let info):
                    completionInfo = info
                case .toolCall(let toolCall):
                    try await chunkWriter.write(toolCall)
                }
            }

            try await chunkWriter.finish()
            try await writer.sendRaw("data: [DONE]\r\n\r\n")
            try await writer.finish()
        } catch {
            await writer.close()
            return
        }
        await logMetrics(
            endpoint: "chat_completions",
            protocolName: writer.protocolName,
            runtimeKind: request.runtimeKind,
            model: model.id,
            streamed: true,
            startedAt: startedAt,
            info: completionInfo
        )
    }

    private func respondToResponses(_ request: HTTPRequest, writer: MLXServerNIOResponseWriter) async throws {
        let body = try request.decode(ResponsesRequest.self)
        let model = try modelCatalog.resolve(id: body.model)
        let thinkingSelection = body.thinkingSelection(for: model.thinking)
        let generationRequest = MLXServerGenerationRequest(
            model: model,
            messages: body.serverMessages,
            parameters: body.generateParameters(
                defaults: model.generationDefaults,
                kvCacheSettings: kvCacheSettings
            ),
            tools: body.toolSpecs,
            additionalContext: model.thinking.additionalContext(for: thinkingSelection),
            retainsReasoningInHistory: thinkingSelection.isEnabled && model.thinking.supportsPreserveThinking
        )

        if body.stream == true {
            try await streamResponses(request: generationRequest, model: model, writer: writer)
            return
        }

        let startedAt = Date()
        let output = try await runtime.generateChatSessionText(request: generationRequest)
        try await writer.sendJSON(
            ResponsesResponse(
                model: model.id,
                text: output.text,
                toolCalls: output.toolCalls,
                emitsThinking: thinkingSelection.isEnabled,
                info: output.info
            )
        )
        await logMetrics(
            endpoint: "responses",
            protocolName: writer.protocolName,
            runtimeKind: generationRequest.runtimeKind,
            model: model.id,
            streamed: false,
            startedAt: startedAt,
            info: output.info
        )
    }

    private func streamResponses(
        request: MLXServerGenerationRequest,
        model: MLXServerModelDescriptor,
        writer: MLXServerNIOResponseWriter
    ) async throws {
        let id = "resp-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let stream = try await runtime.generateChatSession(request: request)
        try await writer.sendSSEHeaders()

        let startedAt = Date()
        var completionInfo: GenerateCompletionInfo?
        var responseWriter = ResponsesStreamingContentWriter(
            writer: writer,
            responseID: id,
            model: model.id,
            emitsThinking: request.emitsThinking
        )
        do {
            try await responseWriter.start()
            for await event in stream {
                switch event {
                case .chunk(let chunk):
                    try await responseWriter.write(chunk)
                case .info(let info):
                    completionInfo = info
                case .toolCall(let toolCall):
                    try await responseWriter.write(toolCall)
                }
            }

            try await responseWriter.finish(info: completionInfo)
            try await writer.finish()
        } catch {
            await writer.close()
            return
        }
        await logMetrics(
            endpoint: "responses",
            protocolName: writer.protocolName,
            runtimeKind: request.runtimeKind,
            model: model.id,
            streamed: true,
            startedAt: startedAt,
            info: completionInfo
        )
    }

    private func respondToAnthropicMessages(_ request: HTTPRequest, writer: MLXServerNIOResponseWriter) async throws {
        let body = try request.decode(AnthropicMessagesRequest.self)
        let model = try modelCatalog.resolve(id: body.model)
        let thinkingSelection = body.thinkingSelection(for: model.thinking)
        let generationRequest = MLXServerGenerationRequest(
            model: model,
            messages: body.serverMessages,
            parameters: body.generateParameters(
                defaults: model.generationDefaults,
                kvCacheSettings: kvCacheSettings
            ),
            tools: body.toolSpecs,
            additionalContext: model.thinking.additionalContext(for: thinkingSelection),
            retainsReasoningInHistory: thinkingSelection.isEnabled && model.thinking.supportsPreserveThinking
        )

        if body.stream == true {
            try await streamAnthropicMessages(request: generationRequest, model: model, writer: writer)
            return
        }

        let startedAt = Date()
        let output = try await runtime.generateChatSessionText(request: generationRequest)
        try await writer.sendJSON(
            AnthropicMessageResponse(
                model: model.id,
                text: output.text,
                toolCalls: output.toolCalls,
                emitsThinking: thinkingSelection.isEnabled,
                info: output.info
            )
        )
        await logMetrics(
            endpoint: "messages",
            protocolName: writer.protocolName,
            runtimeKind: generationRequest.runtimeKind,
            model: model.id,
            streamed: false,
            startedAt: startedAt,
            info: output.info
        )
    }

    private func streamAnthropicMessages(
        request: MLXServerGenerationRequest,
        model: MLXServerModelDescriptor,
        writer: MLXServerNIOResponseWriter
    ) async throws {
        let id = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let stream = try await runtime.generateChatSession(request: request)
        try await writer.sendSSEHeaders()

        let startedAt = Date()
        var completionInfo: GenerateCompletionInfo?
        var blockWriter = AnthropicStreamingContentWriter(
            writer: writer,
            emitsThinking: request.emitsThinking
        )
        var emittedToolCall = false
        do {
            try await writer.sendSSE(
                event: "message_start",
                data: AnthropicMessageStart(id: id, model: model.id)
            )
            for await event in stream {
                switch event {
                case .chunk(let chunk):
                    try await blockWriter.write(chunk)
                case .info(let info):
                    completionInfo = info
                case .toolCall(let toolCall):
                    emittedToolCall = true
                    try await blockWriter.write(toolCall)
                }
            }

            try await blockWriter.finish()
            try await writer.sendSSE(
                event: "message_delta",
                data: AnthropicMessageDelta(stopReason: emittedToolCall ? "tool_use" : "end_turn")
            )
            try await writer.sendSSE(event: "message_stop", data: AnthropicTypedEvent(type: "message_stop"))
            try await writer.finish()
        } catch {
            await writer.close()
            return
        }
        await logMetrics(
            endpoint: "messages",
            protocolName: writer.protocolName,
            runtimeKind: request.runtimeKind,
            model: model.id,
            streamed: true,
            startedAt: startedAt,
            info: completionInfo
        )
    }

    func sendError(_ error: any Error, status: HTTPStatus, writer: MLXServerNIOResponseWriter) async {
        do {
            try await writer.sendJSON(
                ErrorResponse(
                    error: .init(
                        message: error.mlxServerHTTPDescription,
                        type: status.errorType
                    )
                ),
                status: status
            )
        } catch {
            await writer.close()
        }
    }

    private func logRequestError(_ error: any Error, request: HTTPRequest, status: HTTPStatus) {
        let message = """
        mlx-server \(request.method) \(request.path) -> \(status.nioStatus.code): \(error.mlxServerHTTPDescription)
        \(String(reflecting: error))

        """
        try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
    }

    private func logMetrics(
        endpoint: String,
        protocolName: String,
        runtimeKind: MLXServerModelRuntimeKind,
        model: String,
        streamed: Bool,
        startedAt: Date,
        info: GenerateCompletionInfo?
    ) async {
        let cacheEvent = await (runtime as? any MLXServerRuntimeCacheDiagnosing)?
            .consumeLastChatCacheEvent()
        guard let metricsLogger, let info else {
            return
        }

        await metricsLogger.record(
            MLXServerMetricsSample(
                endpoint: endpoint,
                protocolName: protocolName,
                runtimeKind: runtimeKind,
                model: model,
                streamed: streamed,
                wallTime: Date().timeIntervalSince(startedAt),
                promptTokens: info.promptTokenCount,
                generationTokens: info.generationTokenCount,
                promptTime: info.promptTime,
                generationTime: info.generateTime,
                promptTokensPerSecond: info.promptTokensPerSecond,
                generationTokensPerSecond: info.tokensPerSecond,
                cacheEvent: cacheEvent
            )
        )
    }
}

private final class MLXServerNIOHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let application: MLXServerHTTPApplication
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?
    private var pendingResponses: [PendingHTTPResponse] = []
    private var isResponding = false
    private var closeWhenDrained = false

    init(application: MLXServerHTTPApplication) {
        self.application = application
    }

    func handlerAdded(context: ChannelHandlerContext) {
        requestBody = context.channel.allocator.buffer(capacity: 0)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            requestBody?.clear()
        case .body(var body):
            requestBody?.writeBuffer(&body)
        case .end:
            guard let head = requestHead else {
                context.close(promise: nil)
                return
            }
            let request = HTTPRequest(head: head, body: requestBody)
            requestHead = nil
            requestBody?.clear()

            let writer = MLXServerNIOResponseWriter(
                context: NIOLoopBound(context, eventLoop: context.eventLoop),
                eventLoop: context.eventLoop,
                requestVersion: head.version
            )
            pendingResponses.append(PendingHTTPResponse(request: request, writer: writer))
            drainResponses(context: context)
        }
    }

    private func drainResponses(context: ChannelHandlerContext) {
        guard !isResponding, !pendingResponses.isEmpty else {
            return
        }

        isResponding = true
        let pending = pendingResponses.removeFirst()
        let eventLoop = context.eventLoop
        let loopBoundContext = NIOLoopBound(context, eventLoop: eventLoop)
        let loopBoundHandler = NIOLoopBound(self, eventLoop: eventLoop)
        let application = application
        Task {
            await application.respond(to: pending.request, writer: pending.writer)
            eventLoop.execute {
                let handler = loopBoundHandler.value
                handler.isResponding = false
                if handler.pendingResponses.isEmpty, handler.closeWhenDrained {
                    loopBoundContext.value.close(promise: nil)
                    return
                }
                handler.drainResponses(context: loopBoundContext.value)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as ChannelEvent where event == .inputClosed:
            if isResponding || !pendingResponses.isEmpty {
                closeWhenDrained = true
            } else {
                context.close(promise: nil)
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private struct PendingHTTPResponse: Sendable {
    var request: HTTPRequest
    var writer: MLXServerNIOResponseWriter
}

private final class MLXServerNIOErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard !Self.isBenignDisconnect(error) else {
            context.close(promise: nil)
            return
        }
        fputs("mlx-server connection error: \(error)\n", stderr)
        context.close(promise: nil)
    }

    private static func isBenignDisconnect(_ error: any Error) -> Bool {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .inputClosed, .outputClosed:
                return true
            default:
                break
            }
        }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNRESET, EPIPE:
                return true
            default:
                break
            }
        }

        let description = String(describing: error).lowercased()
        return description.contains("connection reset by peer")
            || description.contains("broken pipe")
    }
}

struct MLXServerNIOResponseWriter: Sendable {
    private let context: NIOLoopBound<ChannelHandlerContext>
    private let eventLoop: any EventLoop
    private let requestVersion: HTTPVersion

    var protocolName: String {
        if requestVersion.major == 2 {
            "h2"
        } else {
            "http/\(requestVersion.major).\(requestVersion.minor)"
        }
    }

    init(
        context: NIOLoopBound<ChannelHandlerContext>,
        eventLoop: any EventLoop,
        requestVersion: HTTPVersion
    ) {
        self.context = context
        self.eventLoop = eventLoop
        self.requestVersion = requestVersion
    }

    func sendJSON<T: Encodable>(_ value: T, status: HTTPStatus = .ok) async throws {
        let body = try JSONEncoder.mlxServer.encode(value)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(body.count)")

        let responseHead = HTTPResponseHead(version: requestVersion, status: status.nioStatus, headers: headers)
        try await write(.head(responseHead))
        try await writeBody(Array(body))
        try await finish()
    }

    func sendSSEHeaders() async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")

        let responseHead = HTTPResponseHead(version: requestVersion, status: .ok, headers: headers)
        try await write(.head(responseHead))
    }

    func sendSSE<T: Encodable>(event: String? = nil, data: T) async throws {
        let encoded = try JSONEncoder.mlxServer.encode(data)
        let json = String(decoding: encoded, as: UTF8.self)
        var frame = ""
        if let event {
            frame += "event: \(event)\r\n"
        }
        frame += "data: \(json)\r\n\r\n"
        try await sendRaw(frame)
    }

    func sendRaw(_ text: String) async throws {
        try await writeBody(Array(text.utf8))
    }

    func finish() async throws {
        try await write(.end(nil))
    }

    func close() async {
        await withCheckedContinuation { continuation in
            eventLoop.execute {
                context.value.close(promise: nil)
                continuation.resume()
            }
        }
    }

    private func writeBody(_ bytes: [UInt8]) async throws {
        try await write(.body(.byteBuffer(ByteBuffer(bytes: bytes))))
    }

    private func write(_ part: HTTPServerResponsePart) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            eventLoop.execute {
                let outbound = MLXServerNIOHTTPHandler.wrapOutboundOut(part)
                context.value.writeAndFlush(outbound).whenComplete { result in
                    continuation.resume(with: result)
                }
            }
        }
    }
}

private struct HTTPRequest: Sendable {
    var method: String
    var path: String
    var queryItems: [String: String]
    var headers: [String: String]
    var body: Data

    init(
        method: String,
        path: String,
        queryItems: [String: String] = [:],
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.queryItems = queryItems
        self.headers = headers
        self.body = body
    }

    init(head: HTTPRequestHead, body: ByteBuffer?) {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name.lowercased()] = value
        }

        let route = Self.parseRoute(from: head.uri)
        self.init(
            method: head.method.mlxServerString,
            path: route.path,
            queryItems: route.queryItems,
            headers: headers,
            body: body.map { Data($0.readableBytesView) } ?? Data()
        )
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }

    var bearerToken: String? {
        guard let authorization = headers["authorization"]?.trimmedNonEmpty else {
            return nil
        }
        let prefix = "Bearer "
        guard authorization.count > prefix.count,
              String(authorization.prefix(prefix.count)).caseInsensitiveCompare(prefix) == .orderedSame else {
            return nil
        }
        return String(authorization.dropFirst(prefix.count)).trimmedNonEmpty
    }

    private static func parseRoute(from uri: String) -> (path: String, queryItems: [String: String]) {
        let parts = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = parts.first.map(String.init) ?? uri
        guard parts.count == 2 else {
            return (path, [:])
        }

        var components = URLComponents()
        components.query = String(parts[1])
        let queryItems = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name] = item.value ?? ""
        }
        return (path, queryItems)
    }
}

enum HTTPStatus {
    case ok
    case badRequest
    case unauthorized
    case notFound
    case internalServerError

    var nioStatus: HTTPResponseStatus {
        switch self {
        case .ok:
            .ok
        case .badRequest:
            .badRequest
        case .unauthorized:
            .unauthorized
        case .notFound:
            .notFound
        case .internalServerError:
            .internalServerError
        }
    }

    var errorType: String {
        switch self {
        case .badRequest:
            "invalid_request_error"
        case .unauthorized:
            "authentication_error"
        case .notFound:
            "not_found"
        case .internalServerError:
            "server_error"
        case .ok:
            "ok"
        }
    }
}

private func secureCompare(_ lhs: String, _ rhs: String) -> Bool {
    let lhsBytes = Array(lhs.utf8)
    let rhsBytes = Array(rhs.utf8)
    var difference = lhsBytes.count ^ rhsBytes.count
    for index in 0..<max(lhsBytes.count, rhsBytes.count) {
        let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
        let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
        difference |= Int(lhsByte ^ rhsByte)
    }
    return difference == 0
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Error {
    var mlxServerHTTPDescription: String {
        if let decodingError = self as? DecodingError {
            return decodingError.mlxServerHTTPDescription
        }
        return localizedDescription
    }
}

private extension MLXServerHTTPCustomRequest {
    init(_ request: HTTPRequest) {
        self.init(
            method: request.method,
            path: request.path,
            queryItems: request.queryItems,
            headers: request.headers,
            body: request.body
        )
    }
}

private extension MLXServerHTTPCustomResponseStatus {
    var httpStatus: HTTPStatus {
        switch self {
        case .ok:
            .ok
        case .badRequest:
            .badRequest
        case .notFound:
            .notFound
        case .internalServerError:
            .internalServerError
        }
    }
}

private extension DecodingError {
    var mlxServerHTTPDescription: String {
        let path: String
        let debugDescription: String
        switch self {
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .keyNotFound(_, let context),
             .dataCorrupted(let context):
            path = context.codingPath.map(\.stringValue).joined(separator: ".")
            debugDescription = context.debugDescription
        @unknown default:
            path = ""
            debugDescription = localizedDescription
        }
        let prefix = path.isEmpty ? "Invalid JSON request" : "Invalid JSON request at \(path)"
        return "\(prefix): \(debugDescription)"
    }
}

private enum MLXServerHTTPError: LocalizedError {
    case incompleteTLSConfiguration

    var errorDescription: String? {
        switch self {
        case .incompleteTLSConfiguration:
            "TLS requires both certificate and private key paths in settings.json."
        }
    }
}

private extension HTTPMethod {
    var mlxServerString: String {
        switch self {
        case .GET:
            "GET"
        case .PUT:
            "PUT"
        case .ACL:
            "ACL"
        case .HEAD:
            "HEAD"
        case .POST:
            "POST"
        case .COPY:
            "COPY"
        case .LOCK:
            "LOCK"
        case .MOVE:
            "MOVE"
        case .BIND:
            "BIND"
        case .LINK:
            "LINK"
        case .PATCH:
            "PATCH"
        case .TRACE:
            "TRACE"
        case .MKCOL:
            "MKCOL"
        case .MERGE:
            "MERGE"
        case .PURGE:
            "PURGE"
        case .NOTIFY:
            "NOTIFY"
        case .SEARCH:
            "SEARCH"
        case .UNLOCK:
            "UNLOCK"
        case .REBIND:
            "REBIND"
        case .UNBIND:
            "UNBIND"
        case .REPORT:
            "REPORT"
        case .DELETE:
            "DELETE"
        case .UNLINK:
            "UNLINK"
        case .CONNECT:
            "CONNECT"
        case .MSEARCH:
            "MSEARCH"
        case .OPTIONS:
            "OPTIONS"
        case .PROPFIND:
            "PROPFIND"
        case .CHECKOUT:
            "CHECKOUT"
        case .PROPPATCH:
            "PROPPATCH"
        case .SUBSCRIBE:
            "SUBSCRIBE"
        case .MKCALENDAR:
            "MKCALENDAR"
        case .MKACTIVITY:
            "MKACTIVITY"
        case .UNSUBSCRIBE:
            "UNSUBSCRIBE"
        case .SOURCE:
            "SOURCE"
        case .RAW(let value):
            value
        }
    }
}
