//
//  MLXServerHTTPServer.swift
//  mlx-server
//

import Foundation
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

public final class MLXServerHTTPServer: @unchecked Sendable {
    private let configuration: MLXServerConfiguration
    private let runtime: any MLXServerRuntimeGenerating
    private let modelCatalog: MLXServerModelCatalog
    private let transport: MLXServerHTTPTransportConfiguration
    private let metricsLogger: MLXServerMetricsLogger?
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    private var channel: Channel?

    public init(
        configuration: MLXServerConfiguration,
        runtime: any MLXServerRuntimeGenerating,
        modelCatalog: MLXServerModelCatalog,
        transport: MLXServerHTTPTransportConfiguration = .init(),
        metricsLogger: MLXServerMetricsLogger? = nil
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.modelCatalog = modelCatalog
        self.transport = transport
        self.metricsLogger = metricsLogger
    }

    public func start() throws {
        let sslContext = try makeSSLContext()
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [self] channel in
                configure(channel: channel, sslContext: sslContext)
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

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

    private func configure(channel: Channel, sslContext: NIOSSLContext?) -> EventLoopFuture<Void> {
        if let sslContext {
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
            }.flatMap {
                channel.configureCommonHTTPServerPipeline { streamChannel in
                    self.addApplicationHandlers(to: streamChannel)
                }
            }
        }

        if transport.http2PriorKnowledge {
            return channel.configureHTTP2Pipeline(mode: .server) { streamChannel in
                streamChannel.eventLoop.makeCompletedFuture {
                    let sync = streamChannel.pipeline.syncOperations
                    try sync.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                    try sync.addHandler(MLXServerNIOHTTPHandler(server: self))
                    try sync.addHandler(MLXServerNIOErrorHandler())
                }
            }.flatMap { _ in
                channel.pipeline.addHandler(MLXServerNIOErrorHandler())
            }
        }

        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            self.addApplicationHandlers(to: channel)
        }
    }

    private func addApplicationHandlers(to channel: Channel) -> EventLoopFuture<Void> {
        channel.pipeline.addHandlers([
            MLXServerNIOHTTPHandler(server: self),
            MLXServerNIOErrorHandler()
        ])
    }

    fileprivate func respond(to request: HTTPRequest, writer: MLXServerNIOResponseWriter) async {
        do {
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
        } catch let error as MLXServerModelsManifestError {
            await sendError(error, status: .badRequest, writer: writer)
        } catch {
            await sendError(error, status: .internalServerError, writer: writer)
        }
    }

    private func respondToChatCompletion(_ request: HTTPRequest, writer: MLXServerNIOResponseWriter) async throws {
        let body = try request.decode(OpenAIChatCompletionRequest.self)
        let model = try modelCatalog.resolve(id: body.model)
        let thinkingSelection = body.thinkingSelection(for: model.thinking)
        let generationRequest = MLXServerGenerationRequest(
            model: model,
            messages: body.serverMessages,
            parameters: body.generateParameters(defaults: model.generationDefaults),
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
        try await writer.sendSSEHeaders()
        try await writer.sendSSE(data: ChatCompletionChunk.role(id: id, model: model.id))

        let startedAt = Date()
        var completionInfo: GenerateCompletionInfo?
        var chunkWriter = ChatCompletionStreamingContentWriter(
            writer: writer,
            id: id,
            model: model.id,
            emitsThinking: request.emitsThinking
        )
        let stream = try await runtime.generateChatSession(request: request)
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
            parameters: body.generateParameters(defaults: model.generationDefaults),
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
        try await writer.sendSSEHeaders()

        let startedAt = Date()
        var completionInfo: GenerateCompletionInfo?
        var responseWriter = ResponsesStreamingContentWriter(
            writer: writer,
            responseID: id,
            model: model.id,
            emitsThinking: request.emitsThinking
        )
        try await responseWriter.start()
        let stream = try await runtime.generateChatSession(request: request)
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
            parameters: body.generateParameters(defaults: model.generationDefaults),
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
        try await writer.sendSSEHeaders()
        try await writer.sendSSE(
            event: "message_start",
            data: AnthropicMessageStart(id: id, model: model.id)
        )

        let startedAt = Date()
        var completionInfo: GenerateCompletionInfo?
        var blockWriter = AnthropicStreamingContentWriter(
            writer: writer,
            emitsThinking: request.emitsThinking
        )
        var emittedToolCall = false
        let stream = try await runtime.generateChatSession(request: request)
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

    fileprivate func sendError(_ error: any Error, status: HTTPStatus, writer: MLXServerNIOResponseWriter) async {
        do {
            try await writer.sendJSON(
                ErrorResponse(error: .init(message: error.localizedDescription, type: "server_error")),
                status: status
            )
        } catch {
            await writer.close()
        }
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
                generationTokensPerSecond: info.tokensPerSecond
            )
        )
    }
}

private final class MLXServerNIOHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: MLXServerHTTPServer
    private var requestHead: HTTPRequestHead?
    private var requestBody: ByteBuffer?

    init(server: MLXServerHTTPServer) {
        self.server = server
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
            let server = server
            Task {
                await server.respond(to: request, writer: writer)
            }
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as ChannelEvent where event == .inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

private final class MLXServerNIOErrorHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = Never

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fputs("mlx-server connection error: \(error)\n", stderr)
        context.close(promise: nil)
    }
}

private struct MLXServerNIOResponseWriter: Sendable {
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
        addConnectionCloseIfNeeded(to: &headers)

        let responseHead = HTTPResponseHead(version: requestVersion, status: status.nioStatus, headers: headers)
        try await write(.head(responseHead))
        try await writeBody(Array(body))
        try await finish()
    }

    func sendSSEHeaders() async throws {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/event-stream")
        headers.add(name: "Cache-Control", value: "no-cache")
        addConnectionCloseIfNeeded(to: &headers)

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
        await close()
    }

    func close() async {
        await withCheckedContinuation { continuation in
            eventLoop.execute {
                context.value.close(promise: nil)
                continuation.resume()
            }
        }
    }

    private func addConnectionCloseIfNeeded(to headers: inout HTTPHeaders) {
        if requestVersion.major == 1 {
            headers.add(name: "Connection", value: "close")
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
    var headers: [String: String]
    var body: Data

    init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    init(head: HTTPRequestHead, body: ByteBuffer?) {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name.lowercased()] = value
        }

        let fullPath = head.uri
        let path = fullPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? fullPath
        self.init(
            method: head.method.mlxServerString,
            path: path,
            headers: headers,
            body: body.map { Data($0.readableBytesView) } ?? Data()
        )
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: body)
    }
}

private enum HTTPStatus {
    case ok
    case badRequest
    case notFound
    case internalServerError

    var nioStatus: HTTPResponseStatus {
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

private extension JSONEncoder {
    static var mlxServer: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }
}

private extension JSONValue {
    var sendableValue: any Sendable {
        switch self {
        case .null:
            NSNull()
        case .bool(let value):
            value
        case .int(let value):
            value
        case .double(let value):
            value
        case .string(let value):
            value
        case .array(let values):
            values.map(\.sendableValue)
        case .object(let values):
            values.mapValues(\.sendableValue)
        }
    }
}

private struct FlexibleMessageContent: Decodable, Sendable {
    var text: String
    var imageURLs: [URL]
    var videoURLs: [URL]
    var toolResults: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            imageURLs = []
            videoURLs = []
            toolResults = []
            return
        }

        let parts = try container.decode([ContentPart].self)
        text = parts.compactMap(\.resolvedText).joined(separator: "\n")
        imageURLs = parts.compactMap(\.resolvedImageURL)
        videoURLs = parts.compactMap(\.resolvedVideoURL)
        toolResults = parts.compactMap(\.resolvedToolResult)
    }
}

private struct ContentPart: Decodable, Sendable {
    var type: String?
    var text: String?
    var content: FlexibleNestedTextContent?
    var imageURL: FlexibleURLValue?
    var videoURL: FlexibleURLValue?
    var source: AnthropicMediaSource?
    var toolUseID: String?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case content
        case imageURL = "image_url"
        case videoURL = "video_url"
        case source
        case toolUseID = "tool_use_id"
    }

    var resolvedText: String? {
        switch type {
        case "tool_result", "tool_use":
            nil
        case "text", "input_text", nil:
            text
        default:
            text
        }
    }

    var resolvedImageURL: URL? {
        switch type {
        case "image", "image_url", "input_image":
            imageURL?.url ?? source?.url
        default:
            imageURL?.url
        }
    }

    var resolvedVideoURL: URL? {
        switch type {
        case "video", "video_url", "input_video":
            videoURL?.url ?? source?.url
        default:
            videoURL?.url
        }
    }

    var resolvedToolResult: String? {
        guard type == "tool_result" else {
            return nil
        }

        let body = content?.text ?? text ?? ""
        if let toolUseID {
            return "tool_use_id: \(toolUseID)\n\(body)"
        }
        return body
    }
}

private struct FlexibleNestedTextContent: Decodable, Sendable {
    var text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
            return
        }

        let parts = try container.decode([NestedTextPart].self)
        text = parts.compactMap(\.text).joined(separator: "\n")
    }

    private struct NestedTextPart: Decodable, Sendable {
        var type: String?
        var text: String?
    }
}

private struct FlexibleURLValue: Decodable, Sendable {
    var url: URL?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            url = URL(string: string)
            return
        }

        let object = try container.decode(URLObject.self)
        url = object.url.flatMap(URL.init(string:))
    }

    private struct URLObject: Decodable {
        var url: String?
    }
}

private struct AnthropicMediaSource: Decodable, Sendable {
    var type: String?
    var url: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        url = try container.decodeIfPresent(String.self, forKey: .url).flatMap(URL.init(string:))
    }
}

private struct OpenAIChatCompletionRequest: Decodable, Sendable {
    var model: String?
    var messages: [OpenAIChatMessage]
    var stream: Bool?
    var maxTokens: Int?
    var maxCompletionTokens: Int?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var presencePenalty: Float?
    var frequencyPenalty: Float?
    var tools: [OpenAIChatToolDefinition]?
    var reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case maxTokens = "max_tokens"
        case maxCompletionTokens = "max_completion_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case tools
        case reasoningEffort = "reasoning_effort"
    }

    var serverMessages: [MLXServerChatMessage] {
        messages.flatMap(\.serverMessages)
    }

    var toolSpecs: [ToolSpec]? {
        let specs = tools?.compactMap(\.toolSpec) ?? []
        return specs.isEmpty ? nil : specs
    }

    func thinkingSelection(
        for configuration: MLXServerModelThinkingConfiguration
    ) -> MLXServerThinkingSelection {
        configuration.selection(for: reasoningEffort)
    }

    func generateParameters(defaults: MLXServerModelGenerationDefaults) -> GenerateParameters {
        defaults.generateParameters(
            maxTokens: maxCompletionTokens ?? maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty
        )
    }
}

private struct OpenAIChatMessage: Decodable, Sendable {
    var role: String
    var content: FlexibleMessageContent?
    var toolCallID: String?
    var toolCalls: [OpenAIChatMessageToolCall]?
    var reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
        case reasoningContent = "reasoning_content"
    }

    var serverMessage: MLXServerChatMessage {
        MLXServerChatMessage(
            role: serverRole,
            content: content?.text ?? "",
            imageURLs: content?.imageURLs ?? [],
            videoURLs: content?.videoURLs ?? []
        )
    }

    var serverMessages: [MLXServerChatMessage] {
        switch role {
        case "tool":
            return [.tool(MLXServerToolTranscript.toolOutput(callID: toolCallID, output: content?.text ?? ""))]
        case "assistant":
            var messages: [MLXServerChatMessage] = []
            if let reasoningContent, !reasoningContent.isEmpty {
                messages.append(.assistant(MLXServerReasoningTranscript.reasoningSummary(reasoningContent)))
            }
            if let content, !content.text.isEmpty {
                messages.append(serverMessage)
            }
            messages.append(
                contentsOf: (toolCalls ?? []).map { toolCall in
                    .assistant(MLXServerToolTranscript.toolCall(name: toolCall.function.name, arguments: toolCall.function.arguments))
                }
            )
            if messages.isEmpty {
                messages.append(serverMessage)
            }
            return messages
        default:
            return [serverMessage]
        }
    }

    private var serverRole: MLXServerChatMessage.Role {
        switch role {
        case "system", "developer":
            .system
        case "assistant":
            .assistant
        case "tool":
            .tool
        default:
            .user
        }
    }
}

private struct OpenAIChatToolDefinition: Decodable, Sendable {
    var type: String
    var function: Function?

    struct Function: Decodable, Sendable {
        var name: String
        var description: String?
        var parameters: JSONValue?
        var strict: Bool?
    }

    var toolSpec: ToolSpec? {
        guard type == "function", let function else {
            return nil
        }
        let parameters = function.parameters?.sendableValue
            ?? ["type": "object", "properties": [:] as [String: any Sendable]] as [String: any Sendable]
        return [
            "type": "function",
            "function": [
                "name": function.name,
                "description": function.description ?? "",
                "parameters": parameters,
                "strict": function.strict ?? false
            ] as [String: any Sendable]
        ]
    }
}

private struct OpenAIChatMessageToolCall: Decodable, Sendable {
    var id: String?
    var type: String?
    var function: Function

    struct Function: Decodable, Sendable {
        var name: String
        var arguments: String
    }
}

private struct ChatCompletionResponse: Encodable {
    var id: String = "chatcmpl-\(UUID().uuidString)"
    var object = "chat.completion"
    var created = Int(Date().timeIntervalSince1970)
    var model: String
    var choices: [Choice]
    var usage: Usage
    var mlxMetrics: MLXMetrics?

    init(
        model: String,
        text: String,
        toolCalls: [ToolCall] = [],
        emitsThinking: Bool = false,
        info: GenerateCompletionInfo?
    ) {
        self.model = model
        let content = ChatCompletionOutputContent(text: text, emitsThinking: emitsThinking)
        choices = [
            Choice(
                index: 0,
                message: Message(
                    role: "assistant",
                    content: content.visibleText,
                    reasoningContent: content.reasoningText,
                    toolCalls: toolCalls.isEmpty ? nil : toolCalls.map(ChatCompletionMessageToolCall.init)
                ),
                finishReason: toolCalls.isEmpty ? "stop" : "tool_calls"
            )
        ]
        usage = Usage(info: info)
        mlxMetrics = info.map(MLXMetrics.init)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case model
        case choices
        case usage
        case mlxMetrics = "mlx_metrics"
    }

    struct Choice: Encodable {
        var index: Int
        var message: Message
        var finishReason: String

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Message: Encodable {
        var role: String
        var content: String?
        var reasoningContent: String?
        var toolCalls: [ChatCompletionMessageToolCall]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }
}

private struct ChatCompletionMessageToolCall: Encodable {
    var id: String
    var type = "function"
    var function: Function

    init(_ toolCall: ToolCall) {
        id = ChatCompletionToolCallID.make()
        function = Function(
            name: toolCall.function.name,
            arguments: (try? ResponsesOutputBuilder.encodedJSONString(toolCall.function.arguments)) ?? "{}"
        )
    }

    init(id: String, name: String, arguments: String) {
        self.id = id
        function = Function(name: name, arguments: arguments)
    }

    struct Function: Encodable {
        var name: String
        var arguments: String
    }
}

private enum ChatCompletionToolCallID {
    static func make() -> String {
        "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

private struct ChatCompletionOutputContent {
    var visibleText: String
    var reasoningText: String?

    init(text: String, emitsThinking: Bool) {
        guard emitsThinking else {
            visibleText = text
            reasoningText = nil
            return
        }

        let fragments = AnthropicThinkingSplitter.collect(
            text,
            emitsThinking: true,
            startsInThinking: true
        )
        let reasoning = fragments
            .filter { $0.kind == .thinking }
            .map(\.text)
            .joined()
        visibleText = fragments
            .filter { $0.kind == .text }
            .map(\.text)
            .joined()
        reasoningText = reasoning.isEmpty ? nil : reasoning
    }
}

private struct ChatCompletionChunk: Encodable {
    var id: String
    var object = "chat.completion.chunk"
    var created = Int(Date().timeIntervalSince1970)
    var model: String
    var choices: [Choice]

    static func role(id: String, model: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(role: "assistant"), finishReason: nil)])
    }

    static func delta(id: String, model: String, text: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(content: text), finishReason: nil)])
    }

    static func reasoningDelta(id: String, model: String, text: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(reasoningContent: text), finishReason: nil)])
    }

    static func toolCallDelta(
        id: String,
        model: String,
        index: Int,
        toolCallID: String,
        name: String,
        arguments: String
    ) -> Self {
        Self(
            id: id,
            model: model,
            choices: [
                .init(
                    index: 0,
                    delta: .init(
                        toolCalls: [
                            .init(
                                index: index,
                                id: toolCallID,
                                type: "function",
                                function: .init(name: name, arguments: arguments)
                            )
                        ]
                    ),
                    finishReason: nil
                )
            ]
        )
    }

    static func done(id: String, model: String, finishReason: String) -> Self {
        Self(id: id, model: model, choices: [.init(index: 0, delta: .init(), finishReason: finishReason)])
    }

    struct Choice: Encodable {
        var index: Int
        var delta: Delta
        var finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Encodable {
        var role: String?
        var content: String?
        var reasoningContent: String?
        var toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoningContent = "reasoning_content"
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Encodable {
        var index: Int
        var id: String?
        var type: String?
        var function: Function?

        struct Function: Encodable {
            var name: String?
            var arguments: String?
        }
    }
}

private struct ChatCompletionStreamingContentWriter {
    private let writer: MLXServerNIOResponseWriter
    private let id: String
    private let model: String
    private let emitsThinking: Bool
    private var splitter: AnthropicThinkingSplitter
    private var nextToolCallIndex = 0
    private var emittedToolCall = false

    init(
        writer: MLXServerNIOResponseWriter,
        id: String,
        model: String,
        emitsThinking: Bool
    ) {
        self.writer = writer
        self.id = id
        self.model = model
        self.emitsThinking = emitsThinking
        splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
    }

    mutating func write(_ chunk: String) async throws {
        guard emitsThinking else {
            try await writer.sendSSE(data: ChatCompletionChunk.delta(id: id, model: model, text: chunk))
            return
        }

        for fragment in splitter.consume(chunk) {
            try await write(fragment)
        }
    }

    mutating func write(_ toolCall: ToolCall) async throws {
        if emitsThinking {
            for fragment in splitter.finish() {
                try await write(fragment)
            }
        }

        let toolCallID = ChatCompletionToolCallID.make()
        let arguments = (try? ResponsesOutputBuilder.encodedJSONString(toolCall.function.arguments)) ?? "{}"
        try await writer.sendSSE(
            data: ChatCompletionChunk.toolCallDelta(
                id: id,
                model: model,
                index: nextToolCallIndex,
                toolCallID: toolCallID,
                name: toolCall.function.name,
                arguments: arguments
            )
        )
        nextToolCallIndex += 1
        emittedToolCall = true
    }

    mutating func finish() async throws {
        if emitsThinking {
            for fragment in splitter.finish() {
                try await write(fragment)
            }
        }
        try await writer.sendSSE(
            data: ChatCompletionChunk.done(
                id: id,
                model: model,
                finishReason: emittedToolCall ? "tool_calls" : "stop"
            )
        )
    }

    private func write(_ fragment: AnthropicContentFragment) async throws {
        guard !fragment.text.isEmpty else {
            return
        }
        switch fragment.kind {
        case .text:
            try await writer.sendSSE(data: ChatCompletionChunk.delta(id: id, model: model, text: fragment.text))
        case .thinking:
            try await writer.sendSSE(
                data: ChatCompletionChunk.reasoningDelta(id: id, model: model, text: fragment.text)
            )
        }
    }
}

private struct ResponsesRequest: Decodable, Sendable {
    var model: String?
    var instructions: FlexibleMessageContent?
    var input: ResponsesInput
    var stream: Bool?
    var maxOutputTokens: Int?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var presencePenalty: Float?
    var frequencyPenalty: Float?
    var tools: [ResponsesToolDefinition]?
    var reasoning: ResponsesReasoningConfiguration?

    enum CodingKeys: String, CodingKey {
        case model
        case instructions
        case input
        case stream
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case tools
        case reasoning
    }

    var serverMessages: [MLXServerChatMessage] {
        var messages = input.messages
        if let instructions, !instructions.text.isEmpty {
            messages.insert(.system(instructions.text), at: 0)
        }
        return messages
    }

    var toolSpecs: [ToolSpec]? {
        let specs = tools?.compactMap(\.toolSpec) ?? []
        return specs.isEmpty ? nil : specs
    }

    func thinkingSelection(
        for configuration: MLXServerModelThinkingConfiguration
    ) -> MLXServerThinkingSelection {
        guard let reasoning else {
            return .off
        }
        return configuration.selection(for: reasoning.selectionProtocolValue)
    }

    func generateParameters(defaults: MLXServerModelGenerationDefaults) -> GenerateParameters {
        defaults.generateParameters(
            maxTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty
        )
    }
}

private enum ResponsesInput: Decodable, Sendable {
    case text(String)
    case messages([ResponsesInputItem])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .messages(try container.decode([ResponsesInputItem].self))
        }
    }

    var messages: [MLXServerChatMessage] {
        switch self {
        case .text(let text):
            [.user(text)]
        case .messages(let messages):
            messages.flatMap(\.serverMessages)
        }
    }
}

private struct ResponsesInputItem: Decodable, Sendable {
    var type: String?
    var role: String?
    var content: FlexibleMessageContent?
    var callID: String?
    var output: FlexibleMessageContent?
    var name: String?
    var arguments: String?
    var summary: [ResponsesReasoningSummaryContent]?

    enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case callID = "call_id"
        case output
        case name
        case arguments
        case summary
    }

    var serverMessages: [MLXServerChatMessage] {
        switch type {
        case "function_call_output":
            return [.tool(MLXServerToolTranscript.toolOutput(callID: callID, output: output?.text ?? ""))]
        case "function_call":
            return [
                MLXServerChatMessage(
                    role: .assistant,
                    content: MLXServerToolTranscript.toolCall(name: name ?? "", arguments: arguments ?? "")
                )
            ]
        case "reasoning":
            let text = summary?.map(\.text).joined(separator: "\n") ?? ""
            guard !text.isEmpty else {
                return []
            }
            return [.assistant(MLXServerReasoningTranscript.reasoningSummary(text))]
        default:
            guard let role else {
                return content.map { [.user($0.text)] } ?? []
            }
            return [
                MLXServerChatMessage(
                    role: serverRole(for: role),
                    content: content?.text ?? "",
                    imageURLs: content?.imageURLs ?? [],
                    videoURLs: content?.videoURLs ?? []
                )
            ]
        }
    }

    private func serverRole(for role: String) -> MLXServerChatMessage.Role {
        switch role {
        case "system", "developer":
            .system
        case "assistant":
            .assistant
        case "tool":
            .tool
        default:
            .user
        }
    }
}

private struct ResponsesReasoningSummaryContent: Decodable, Sendable {
    var type: String?
    var text: String
}

private struct ResponsesToolDefinition: Decodable, Sendable {
    var type: String
    var name: String?
    var description: String?
    var parameters: JSONValue?
    var strict: Bool?

    var toolSpec: ToolSpec? {
        guard type == "function", let name else {
            return nil
        }
        let parameters = parameters?.sendableValue
            ?? ["type": "object", "properties": [:] as [String: any Sendable]] as [String: any Sendable]
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description ?? "",
                "parameters": parameters,
                "strict": strict ?? false
            ] as [String: any Sendable]
        ]
    }
}

private struct ResponsesReasoningConfiguration: Decodable, Sendable {
    var effort: String?
    var summary: String?

    var emitsThinking: Bool {
        guard summary != "none", effort != "none" else {
            return false
        }
        return summary != nil || effort != nil
    }

    var selectionProtocolValue: String? {
        emitsThinking ? (effort ?? "enabled") : "none"
    }
}

private struct ResponsesResponse: Encodable {
    var id = "resp-\(UUID().uuidString)"
    var object = "response"
    var createdAt = Int(Date().timeIntervalSince1970)
    var status = "completed"
    var model: String
    var output: [ResponsesOutputItem]
    var usage: Usage
    var mlxMetrics: MLXMetrics?

    init(
        id: String = "resp-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        model: String,
        text: String,
        toolCalls: [ToolCall] = [],
        emitsThinking: Bool = false,
        info: GenerateCompletionInfo?
    ) {
        self.id = id
        self.model = model
        output = ResponsesOutputBuilder.outputItems(
            text: text,
            toolCalls: toolCalls,
            emitsThinking: emitsThinking
        )
        usage = Usage(info: info)
        mlxMetrics = info.map(MLXMetrics.init)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case status
        case model
        case output
        case usage
        case mlxMetrics = "mlx_metrics"
    }
}

private enum ResponsesOutputBuilder {
    static func outputItems(
        text: String,
        toolCalls: [ToolCall],
        emitsThinking: Bool
    ) -> [ResponsesOutputItem] {
        var output: [ResponsesOutputItem] = []
        let fragments = AnthropicThinkingSplitter.collect(
            text,
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
        let reasoning = fragments
            .filter { $0.kind == .thinking }
            .map(\.text)
            .joined()
        let visibleText = fragments
            .filter { $0.kind == .text }
            .map(\.text)
            .joined()

        if !reasoning.isEmpty {
            output.append(.reasoning(id: responseReasoningID(), status: "completed", summary: reasoning))
        }
        if !visibleText.isEmpty {
            output.append(.message(id: responseMessageID(), status: "completed", text: visibleText))
        }
        output.append(contentsOf: toolCalls.map { toolCall in
            .functionCall(
                id: responseFunctionCallID(),
                callID: responseCallID(),
                status: "completed",
                name: toolCall.function.name,
                arguments: (try? encodedJSONString(toolCall.function.arguments)) ?? "{}"
            )
        })
        return output
    }

    static func responseMessageID() -> String {
        "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func responseReasoningID() -> String {
        "rs_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func responseFunctionCallID() -> String {
        "fc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func responseCallID() -> String {
        "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    static func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private enum ResponsesOutputItem: Encodable {
    case message(id: String, status: String, text: String)
    case reasoning(id: String, status: String, summary: String)
    case functionCall(id: String, callID: String, status: String, name: String, arguments: String)

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case status
        case role
        case content
        case summary
        case callID = "call_id"
        case name
        case arguments
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let id, let status, let text):
            try container.encode(id, forKey: .id)
            try container.encode("message", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode("assistant", forKey: .role)
            let content = text.isEmpty ? [] : [ResponsesContentPart.outputText(text)]
            try container.encode(content, forKey: .content)
        case .reasoning(let id, let status, let summary):
            try container.encode(id, forKey: .id)
            try container.encode("reasoning", forKey: .type)
            try container.encode(status, forKey: .status)
            let content = summary.isEmpty ? [] : [ResponsesContentPart.summaryText(summary)]
            try container.encode(content, forKey: .summary)
        case .functionCall(let id, let callID, let status, let name, let arguments):
            try container.encode(id, forKey: .id)
            try container.encode("function_call", forKey: .type)
            try container.encode(status, forKey: .status)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

private enum ResponsesContentPart: Encodable {
    case outputText(String)
    case summaryText(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case annotations
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .outputText(let text):
            try container.encode("output_text", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode([String](), forKey: .annotations)
        case .summaryText(let text):
            try container.encode("summary_text", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

private struct ResponsesOutputTextDelta: Encodable {
    var type = "response.output_text.delta"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var delta: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case delta
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesStreamingContentWriter {
    private let writer: MLXServerNIOResponseWriter
    private let responseID: String
    private let model: String
    private var splitter: AnthropicThinkingSplitter
    private var sequenceNumber = 0
    private var nextOutputIndex = 0
    private var currentItem: ResponsesStreamItem?
    private var outputItems: [ResponsesOutputItem] = []

    init(
        writer: MLXServerNIOResponseWriter,
        responseID: String,
        model: String,
        emitsThinking: Bool
    ) {
        self.writer = writer
        self.responseID = responseID
        self.model = model
        splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
    }

    mutating func start() async throws {
        try await send(
            event: "response.created",
            data: ResponsesLifecycleEvent(
                type: "response.created",
                response: ResponsesStreamResponse(id: responseID, model: model, status: "in_progress"),
                sequenceNumber: nextSequenceNumber()
            )
        )
        try await send(
            event: "response.in_progress",
            data: ResponsesLifecycleEvent(
                type: "response.in_progress",
                response: ResponsesStreamResponse(id: responseID, model: model, status: "in_progress"),
                sequenceNumber: nextSequenceNumber()
            )
        )
    }

    mutating func write(_ chunk: String) async throws {
        for fragment in splitter.consume(chunk) {
            try await write(fragment)
        }
    }

    mutating func write(_ toolCall: ToolCall) async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentItem()

        let itemID = ResponsesOutputBuilder.responseFunctionCallID()
        let callID = ResponsesOutputBuilder.responseCallID()
        let outputIndex = nextOutputIndex
        nextOutputIndex += 1
        let arguments = (try? ResponsesOutputBuilder.encodedJSONString(toolCall.function.arguments)) ?? "{}"

        try await send(
            event: "response.output_item.added",
            data: ResponsesOutputItemAdded(
                responseID: responseID,
                outputIndex: outputIndex,
                item: .functionCall(
                    id: itemID,
                    callID: callID,
                    status: "in_progress",
                    name: toolCall.function.name,
                    arguments: ""
                ),
                sequenceNumber: nextSequenceNumber()
            )
        )
        try await send(
            event: "response.function_call_arguments.delta",
            data: ResponsesFunctionCallArgumentsDelta(
                responseID: responseID,
                itemID: itemID,
                outputIndex: outputIndex,
                delta: arguments,
                sequenceNumber: nextSequenceNumber()
            )
        )
        try await send(
            event: "response.function_call_arguments.done",
            data: ResponsesFunctionCallArgumentsDone(
                responseID: responseID,
                itemID: itemID,
                outputIndex: outputIndex,
                name: toolCall.function.name,
                arguments: arguments,
                sequenceNumber: nextSequenceNumber()
            )
        )

        let item = ResponsesOutputItem.functionCall(
            id: itemID,
            callID: callID,
            status: "completed",
            name: toolCall.function.name,
            arguments: arguments
        )
        try await send(
            event: "response.output_item.done",
            data: ResponsesOutputItemDone(
                responseID: responseID,
                outputIndex: outputIndex,
                item: item,
                sequenceNumber: nextSequenceNumber()
            )
        )
        outputItems.append(item)
    }

    mutating func finish(info: GenerateCompletionInfo?) async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentItem()
        try await send(
            event: "response.completed",
            data: ResponsesLifecycleEvent(
                type: "response.completed",
                response: ResponsesStreamResponse(
                    id: responseID,
                    model: model,
                    status: "completed",
                    output: outputItems,
                    usage: Usage(info: info),
                    mlxMetrics: info.map(MLXMetrics.init)
                ),
                sequenceNumber: nextSequenceNumber()
            )
        )
    }

    private mutating func write(_ fragment: AnthropicContentFragment) async throws {
        guard !fragment.text.isEmpty else {
            return
        }
        if currentItem?.kind != fragment.kind {
            try await stopCurrentItem()
            try await startItem(kind: fragment.kind)
        }
        guard var item = currentItem else {
            return
        }
        item.text += fragment.text
        currentItem = item

        switch item.kind {
        case .text:
            try await send(
                event: "response.output_text.delta",
                data: ResponsesOutputTextDelta(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    delta: fragment.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
        case .thinking:
            try await send(
                event: "response.reasoning_summary_text.delta",
                data: ResponsesReasoningSummaryTextDelta(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    delta: fragment.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
        }
    }

    private mutating func startItem(kind: AnthropicContentFragment.Kind) async throws {
        let item = ResponsesStreamItem(
            kind: kind,
            id: kind == .text
                ? ResponsesOutputBuilder.responseMessageID()
                : ResponsesOutputBuilder.responseReasoningID(),
            outputIndex: nextOutputIndex
        )
        currentItem = item
        nextOutputIndex += 1

        let outputItem: ResponsesOutputItem = kind == .text
            ? .message(id: item.id, status: "in_progress", text: "")
            : .reasoning(id: item.id, status: "in_progress", summary: "")
        try await send(
            event: "response.output_item.added",
            data: ResponsesOutputItemAdded(
                responseID: responseID,
                outputIndex: item.outputIndex,
                item: outputItem,
                sequenceNumber: nextSequenceNumber()
            )
        )

        switch kind {
        case .text:
            try await send(
                event: "response.content_part.added",
                data: ResponsesContentPartAdded(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    part: .outputText(""),
                    sequenceNumber: nextSequenceNumber()
                )
            )
        case .thinking:
            try await send(
                event: "response.reasoning_summary_part.added",
                data: ResponsesReasoningSummaryPartAdded(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    part: .summaryText(""),
                    sequenceNumber: nextSequenceNumber()
                )
            )
        }
    }

    private mutating func stopCurrentItem() async throws {
        guard let item = currentItem else {
            return
        }

        let outputItem: ResponsesOutputItem
        switch item.kind {
        case .text:
            try await send(
                event: "response.output_text.done",
                data: ResponsesOutputTextDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    text: item.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
            try await send(
                event: "response.content_part.done",
                data: ResponsesContentPartDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    contentIndex: 0,
                    part: .outputText(item.text),
                    sequenceNumber: nextSequenceNumber()
                )
            )
            outputItem = .message(id: item.id, status: "completed", text: item.text)
        case .thinking:
            try await send(
                event: "response.reasoning_summary_text.done",
                data: ResponsesReasoningSummaryTextDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    text: item.text,
                    sequenceNumber: nextSequenceNumber()
                )
            )
            try await send(
                event: "response.reasoning_summary_part.done",
                data: ResponsesReasoningSummaryPartDone(
                    responseID: responseID,
                    itemID: item.id,
                    outputIndex: item.outputIndex,
                    summaryIndex: 0,
                    part: .summaryText(item.text),
                    sequenceNumber: nextSequenceNumber()
                )
            )
            outputItem = .reasoning(id: item.id, status: "completed", summary: item.text)
        }

        try await send(
            event: "response.output_item.done",
            data: ResponsesOutputItemDone(
                responseID: responseID,
                outputIndex: item.outputIndex,
                item: outputItem,
                sequenceNumber: nextSequenceNumber()
            )
        )
        outputItems.append(outputItem)
        currentItem = nil
    }

    private mutating func nextSequenceNumber() -> Int {
        sequenceNumber += 1
        return sequenceNumber
    }

    private func send<T: Encodable>(event: String, data: T) async throws {
        try await writer.sendSSE(event: event, data: data)
    }
}

private struct ResponsesStreamItem {
    var kind: AnthropicContentFragment.Kind
    var id: String
    var outputIndex: Int
    var text = ""
}

private struct ResponsesStreamResponse: Encodable {
    var id: String
    var object = "response"
    var createdAt = Int(Date().timeIntervalSince1970)
    var status: String
    var model: String
    var output: [ResponsesOutputItem]
    var usage: Usage?
    var mlxMetrics: MLXMetrics?

    init(
        id: String,
        model: String,
        status: String,
        output: [ResponsesOutputItem] = [],
        usage: Usage? = nil,
        mlxMetrics: MLXMetrics? = nil
    ) {
        self.id = id
        self.status = status
        self.model = model
        self.output = output
        self.usage = usage
        self.mlxMetrics = mlxMetrics
    }

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case createdAt = "created_at"
        case status
        case model
        case output
        case usage
        case mlxMetrics = "mlx_metrics"
    }
}

private struct ResponsesLifecycleEvent: Encodable {
    var type: String
    var response: ResponsesStreamResponse
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case response
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesOutputItemAdded: Encodable {
    var type = "response.output_item.added"
    var responseID: String
    var outputIndex: Int
    var item: ResponsesOutputItem
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case outputIndex = "output_index"
        case item
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesOutputItemDone: Encodable {
    var type = "response.output_item.done"
    var responseID: String
    var outputIndex: Int
    var item: ResponsesOutputItem
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case outputIndex = "output_index"
        case item
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesContentPartAdded: Encodable {
    var type = "response.content_part.added"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesContentPartDone: Encodable {
    var type = "response.content_part.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesOutputTextDone: Encodable {
    var type = "response.output_text.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var contentIndex: Int
    var text: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case contentIndex = "content_index"
        case text
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesReasoningSummaryPartAdded: Encodable {
    var type = "response.reasoning_summary_part.added"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesReasoningSummaryPartDone: Encodable {
    var type = "response.reasoning_summary_part.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var part: ResponsesContentPart
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case part
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesReasoningSummaryTextDelta: Encodable {
    var type = "response.reasoning_summary_text.delta"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var delta: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case delta
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesReasoningSummaryTextDone: Encodable {
    var type = "response.reasoning_summary_text.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var summaryIndex: Int
    var text: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case summaryIndex = "summary_index"
        case text
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesFunctionCallArgumentsDelta: Encodable {
    var type = "response.function_call_arguments.delta"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var delta: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case delta
        case sequenceNumber = "sequence_number"
    }
}

private struct ResponsesFunctionCallArgumentsDone: Encodable {
    var type = "response.function_call_arguments.done"
    var responseID: String
    var itemID: String
    var outputIndex: Int
    var name: String
    var arguments: String
    var sequenceNumber: Int

    enum CodingKeys: String, CodingKey {
        case type
        case responseID = "response_id"
        case itemID = "item_id"
        case outputIndex = "output_index"
        case name
        case arguments
        case sequenceNumber = "sequence_number"
    }
}

private struct AnthropicMessagesRequest: Decodable, Sendable {
    var model: String?
    var maxTokens: Int?
    var system: FlexibleMessageContent?
    var messages: [AnthropicInputMessage]
    var stream: Bool?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var presencePenalty: Float?
    var frequencyPenalty: Float?
    var tools: [AnthropicToolDefinition]?
    var thinking: AnthropicThinkingConfiguration?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
        case tools
        case thinking
    }

    var serverMessages: [MLXServerChatMessage] {
        var result: [MLXServerChatMessage] = []
        if let system, !system.text.isEmpty {
            result.append(.system(system.text))
        }
        result.append(contentsOf: messages.flatMap(\.serverMessages))
        return result
    }

    var toolSpecs: [ToolSpec]? {
        let specs = tools?.compactMap(\.toolSpec) ?? []
        return specs.isEmpty ? nil : specs
    }

    func thinkingSelection(
        for configuration: MLXServerModelThinkingConfiguration
    ) -> MLXServerThinkingSelection {
        guard thinking?.emitsThinking == true else {
            return .off
        }
        return configuration.defaultEnabledSelection()
    }

    func generateParameters(defaults: MLXServerModelGenerationDefaults) -> GenerateParameters {
        defaults.generateParameters(
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty
        )
    }
}

private struct AnthropicInputMessage: Decodable, Sendable {
    var role: String
    var content: FlexibleMessageContent

    var serverMessage: MLXServerChatMessage {
        MLXServerChatMessage(
            role: serverRole,
            content: content.text,
            imageURLs: content.imageURLs,
            videoURLs: content.videoURLs
        )
    }

    var serverMessages: [MLXServerChatMessage] {
        if role == "user", !content.toolResults.isEmpty {
            var result: [MLXServerChatMessage] = []
            if !content.text.isEmpty {
                result.append(
                    MLXServerChatMessage(
                        role: .user,
                        content: content.text,
                        imageURLs: content.imageURLs,
                        videoURLs: content.videoURLs
                    )
                )
            }
            result.append(contentsOf: content.toolResults.map(MLXServerChatMessage.tool))
            return result
        }
        return [serverMessage]
    }

    private var serverRole: MLXServerChatMessage.Role {
        switch role {
        case "system":
            .system
        case "assistant":
            .assistant
        case "tool":
            .tool
        default:
            .user
        }
    }
}

private struct AnthropicThinkingConfiguration: Decodable, Sendable {
    var type: String?
    var display: String?

    var emitsThinking: Bool {
        guard type != "disabled", display != "omitted" else {
            return false
        }
        return type != nil || display != nil
    }
}

private struct AnthropicToolDefinition: Decodable, Sendable {
    var name: String?
    var description: String?
    var inputSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case inputSchema = "input_schema"
    }

    var toolSpec: ToolSpec? {
        guard let name else {
            return nil
        }

        let parameters = inputSchema?.sendableValue
            ?? ["type": "object", "properties": [:] as [String: any Sendable]] as [String: any Sendable]

        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description ?? "",
                "parameters": parameters
            ] as [String: any Sendable]
        ]
    }
}

private struct AnthropicStreamingContentWriter {
    private let writer: MLXServerNIOResponseWriter
    private var splitter: AnthropicThinkingSplitter
    private var currentBlock: AnthropicStreamBlock?
    private var nextIndex = 0

    init(writer: MLXServerNIOResponseWriter, emitsThinking: Bool) {
        self.writer = writer
        splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        )
    }

    mutating func write(_ chunk: String) async throws {
        for fragment in splitter.consume(chunk) {
            try await write(fragment)
        }
    }

    mutating func write(_ toolCall: ToolCall) async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentBlock()

        let index = nextIndex
        nextIndex += 1
        let id = AnthropicToolUseID.make()
        try await writer.sendSSE(
            event: "content_block_start",
            data: AnthropicContentBlockStart(
                index: index,
                contentBlock: .toolUse(id: id, name: toolCall.function.name)
            )
        )
        try await writer.sendSSE(
            event: "content_block_delta",
            data: AnthropicContentBlockDelta(
                index: index,
                delta: .inputJSON(try encodedJSONString(toolCall.function.arguments))
            )
        )
        try await writer.sendSSE(
            event: "content_block_stop",
            data: AnthropicIndexedEvent(type: "content_block_stop", index: index)
        )
    }

    mutating func finish() async throws {
        for fragment in splitter.finish() {
            try await write(fragment)
        }
        try await stopCurrentBlock()
    }

    private mutating func write(_ fragment: AnthropicContentFragment) async throws {
        guard !fragment.text.isEmpty else {
            return
        }
        if currentBlock?.kind != fragment.kind {
            try await stopCurrentBlock()
            try await startBlock(AnthropicStreamBlock(kind: fragment.kind))
        }
        guard let block = currentBlock else {
            return
        }
        try await writer.sendSSE(
            event: "content_block_delta",
            data: AnthropicContentBlockDelta(
                index: block.index,
                delta: fragment.kind == .text
                    ? .text(fragment.text)
                    : .thinking(fragment.text)
            )
        )
    }

    private mutating func startBlock(_ block: AnthropicStreamBlock) async throws {
        var block = block
        block.index = nextIndex
        nextIndex += 1
        currentBlock = block

        try await writer.sendSSE(
            event: "content_block_start",
            data: AnthropicContentBlockStart(
                index: block.index,
                contentBlock: block.kind == .text ? .text : .thinking
            )
        )
    }

    private mutating func stopCurrentBlock() async throws {
        guard let block = currentBlock else {
            return
        }
        if block.kind == .thinking {
            try await writer.sendSSE(
                event: "content_block_delta",
                data: AnthropicContentBlockDelta(index: block.index, delta: .signature(""))
            )
        }
        try await writer.sendSSE(
            event: "content_block_stop",
            data: AnthropicIndexedEvent(type: "content_block_stop", index: block.index)
        )
        currentBlock = nil
    }

    private func encodedJSONString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder.mlxServer.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

private struct AnthropicStreamBlock: Equatable {
    var kind: AnthropicContentFragment.Kind
    var index = -1

    init(kind: AnthropicContentFragment.Kind) {
        self.kind = kind
    }
}

private struct AnthropicContentFragment: Equatable {
    enum Kind: Equatable {
        case text
        case thinking
    }

    var kind: Kind
    var text: String
}

private struct AnthropicThinkingSplitter {
    private enum Mode {
        case text
        case thinking
        case discardingThinking
    }

    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    private let emitsThinking: Bool
    private var mode: Mode
    private var buffer = ""

    init(emitsThinking: Bool, startsInThinking: Bool) {
        self.emitsThinking = emitsThinking
        mode = startsInThinking
            ? (emitsThinking ? .thinking : .discardingThinking)
            : .text
    }

    mutating func consume(_ chunk: String) -> [AnthropicContentFragment] {
        buffer += chunk
        return drain(flush: false)
    }

    mutating func finish() -> [AnthropicContentFragment] {
        drain(flush: true)
    }

    static func collect(
        _ text: String,
        emitsThinking: Bool,
        startsInThinking: Bool
    ) -> [AnthropicContentFragment] {
        var splitter = AnthropicThinkingSplitter(
            emitsThinking: emitsThinking,
            startsInThinking: startsInThinking
        )
        var fragments = splitter.consume(text)
        fragments.append(contentsOf: splitter.finish())
        return fragments
    }

    private mutating func drain(flush: Bool) -> [AnthropicContentFragment] {
        var fragments: [AnthropicContentFragment] = []

        while !buffer.isEmpty {
            switch mode {
            case .text:
                if let closeRange = firstRange(of: Self.closeTag),
                   range(Self.openTag, occursAfter: closeRange) || firstRange(of: Self.openTag) == nil {
                    buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                    continue
                }

                if let openRange = firstRange(of: Self.openTag) {
                    appendText(
                        String(buffer[..<openRange.lowerBound]),
                        kind: .text,
                        to: &fragments
                    )
                    buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                    mode = emitsThinking ? .thinking : .discardingThinking
                    continue
                }

                let text = consumableText(flush: flush, tags: [Self.openTag, Self.closeTag])
                guard !text.isEmpty else {
                    break
                }
                appendText(text, kind: .text, to: &fragments)
                buffer.removeFirst(text.count)

            case .thinking, .discardingThinking:
                if let openRange = firstRange(of: Self.openTag),
                   openRange.lowerBound == buffer.startIndex {
                    buffer.removeSubrange(buffer.startIndex..<openRange.upperBound)
                    continue
                }

                if let closeRange = firstRange(of: Self.closeTag) {
                    if mode == .thinking {
                        appendText(
                            String(buffer[..<closeRange.lowerBound]),
                            kind: .thinking,
                            to: &fragments
                        )
                    }
                    buffer.removeSubrange(buffer.startIndex..<closeRange.upperBound)
                    mode = .text
                    continue
                }

                let text = consumableText(flush: flush, tags: [Self.openTag, Self.closeTag])
                guard !text.isEmpty else {
                    break
                }
                if mode == .thinking {
                    appendText(text, kind: .thinking, to: &fragments)
                }
                buffer.removeFirst(text.count)
            }
        }

        return fragments
    }

    private mutating func appendText(
        _ text: String,
        kind: AnthropicContentFragment.Kind,
        to fragments: inout [AnthropicContentFragment]
    ) {
        guard !text.isEmpty else {
            return
        }
        if fragments.last?.kind == kind {
            fragments[fragments.count - 1].text += text
        } else {
            fragments.append(.init(kind: kind, text: text))
        }
    }

    private func firstRange(of tag: String) -> Range<String.Index>? {
        buffer.range(of: tag)
    }

    private func range(_ tag: String, occursAfter other: Range<String.Index>) -> Bool {
        guard let range = firstRange(of: tag) else {
            return true
        }
        return range.lowerBound > other.lowerBound
    }

    private func consumableText(flush: Bool, tags: [String]) -> String {
        if flush {
            return buffer
        }

        let retained = retainedTagPrefixLength(tags: tags)
        guard retained > 0 else {
            return buffer
        }
        return String(buffer.dropLast(retained))
    }

    private func retainedTagPrefixLength(tags: [String]) -> Int {
        var best = 0
        for tag in tags {
            let maxLength = min(buffer.count, tag.count - 1)
            guard maxLength > 0 else {
                continue
            }
            for length in 1...maxLength {
                if buffer.hasSuffix(String(tag.prefix(length))) {
                    best = max(best, length)
                }
            }
        }
        return best
    }
}

private enum AnthropicToolUseID {
    static func make() -> String {
        "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

private struct AnthropicMessageResponse: Encodable {
    var id = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    var type = "message"
    var role = "assistant"
    var model: String
    var content: [AnthropicResponseContent]
    var stopReason: String
    var stopSequence: String?
    var usage: AnthropicUsage
    var mlxMetrics: MLXMetrics?

    init(
        model: String,
        text: String,
        toolCalls: [ToolCall],
        emitsThinking: Bool,
        info: GenerateCompletionInfo?
    ) {
        self.model = model
        content = AnthropicThinkingSplitter.collect(
            text,
            emitsThinking: emitsThinking,
            startsInThinking: emitsThinking
        ).map { fragment in
            switch fragment.kind {
            case .text:
                .text(fragment.text)
            case .thinking:
                .thinking(fragment.text)
            }
        }
        content.append(
            contentsOf: toolCalls.map { toolCall in
                .toolUse(
                    id: AnthropicToolUseID.make(),
                    name: toolCall.function.name,
                    input: toolCall.function.arguments
                )
            }
        )
        stopReason = toolCalls.isEmpty ? "end_turn" : "tool_use"
        usage = AnthropicUsage(info: info)
        mlxMetrics = info.map(MLXMetrics.init)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case role
        case model
        case content
        case stopReason = "stop_reason"
        case stopSequence = "stop_sequence"
        case usage
        case mlxMetrics = "mlx_metrics"
    }

}

private enum AnthropicResponseContent: Encodable {
    case text(String)
    case thinking(String)
    case toolUse(id: String, name: String, input: [String: JSONValue])

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case signature
        case id
        case name
        case input
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking):
            try container.encode("thinking", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
            try container.encode("", forKey: .signature)
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        }
    }
}

private struct AnthropicMessageStart: Encodable {
    var type = "message_start"
    var message: Message

    init(id: String, model: String) {
        message = Message(id: id, model: model)
    }

    struct Message: Encodable {
        var id: String
        var type = "message"
        var role = "assistant"
        var model: String
        var content: [String] = []
        var stopReason: String?
        var stopSequence: String?
        var usage = AnthropicUsage(inputTokens: 0, outputTokens: 0)

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case role
            case model
            case content
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
            case usage
        }
    }
}

private struct AnthropicContentBlockStart: Encodable {
    var type = "content_block_start"
    var index: Int
    var contentBlock: AnthropicContentBlock

    enum CodingKeys: String, CodingKey {
        case type
        case index
        case contentBlock = "content_block"
    }
}

private enum AnthropicContentBlock: Encodable {
    case text
    case thinking
    case toolUse(id: String, name: String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case signature
        case id
        case name
        case input
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text:
            try container.encode("text", forKey: .type)
            try container.encode("", forKey: .text)
        case .thinking:
            try container.encode("thinking", forKey: .type)
            try container.encode("", forKey: .thinking)
            try container.encode("", forKey: .signature)
        case .toolUse(let id, let name):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode([String: JSONValue](), forKey: .input)
        }
    }
}

private struct AnthropicContentBlockDelta: Encodable {
    var type = "content_block_delta"
    var index: Int
    var delta: AnthropicContentDelta

}

private enum AnthropicContentDelta: Encodable {
    case text(String)
    case thinking(String)
    case inputJSON(String)
    case signature(String)

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case thinking
        case partialJSON = "partial_json"
        case signature
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text_delta", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let thinking):
            try container.encode("thinking_delta", forKey: .type)
            try container.encode(thinking, forKey: .thinking)
        case .inputJSON(let partialJSON):
            try container.encode("input_json_delta", forKey: .type)
            try container.encode(partialJSON, forKey: .partialJSON)
        case .signature(let signature):
            try container.encode("signature_delta", forKey: .type)
            try container.encode(signature, forKey: .signature)
        }
    }
}

private struct AnthropicMessageDelta: Encodable {
    var type = "message_delta"
    var delta: Delta
    var usage = AnthropicUsage(inputTokens: 0, outputTokens: 0)

    init(stopReason: String) {
        delta = Delta(stopReason: stopReason, stopSequence: nil)
    }

    struct Delta: Encodable {
        var stopReason: String
        var stopSequence: String?

        enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case stopSequence = "stop_sequence"
        }
    }
}

private struct AnthropicIndexedEvent: Encodable {
    var type: String
    var index: Int = 0
}

private struct AnthropicTypedEvent: Encodable {
    var type: String
}

private struct Usage: Encodable {
    var promptTokens: Int
    var completionTokens: Int
    var totalTokens: Int

    init(info: GenerateCompletionInfo?) {
        promptTokens = info?.promptTokenCount ?? 0
        completionTokens = info?.generationTokenCount ?? 0
        totalTokens = promptTokens + completionTokens
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

private struct MLXMetrics: Encodable {
    var promptTime: Double
    var generationTime: Double
    var promptTokensPerSecond: Double
    var generationTokensPerSecond: Double

    init(info: GenerateCompletionInfo) {
        promptTime = info.promptTime
        generationTime = info.generateTime
        promptTokensPerSecond = info.promptTokensPerSecond
        generationTokensPerSecond = info.tokensPerSecond
    }

    enum CodingKeys: String, CodingKey {
        case promptTime = "prompt_time"
        case generationTime = "generation_time"
        case promptTokensPerSecond = "prompt_tokens_per_second"
        case generationTokensPerSecond = "generation_tokens_per_second"
    }
}

private struct AnthropicUsage: Encodable {
    var inputTokens: Int
    var outputTokens: Int

    init(info: GenerateCompletionInfo?) {
        inputTokens = info?.promptTokenCount ?? 0
        outputTokens = info?.generationTokenCount ?? 0
    }

    init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }
}

private struct ModelsResponse: Encodable {
    var object = "list"

    var data: [Model]

    init(models: [MLXServerModelDescriptor]) {
        self.data = models.map { model in
            Model(id: model.id, ownedBy: Self.owner(for: model.id))
        }
    }

    private static func owner(for id: String) -> String {
        guard let owner = id.split(separator: "/", maxSplits: 1).first, !owner.isEmpty else {
            return "local"
        }
        return String(owner)
    }

    struct Model: Encodable {
        var id: String
        var object = "model"
        var created = 0
        var ownedBy: String

        enum CodingKeys: String, CodingKey {
            case id
            case object
            case created
            case ownedBy = "owned_by"
        }
    }
}

private struct ErrorResponse: Encodable {
    var error: ErrorBody

    struct ErrorBody: Encodable {
        var message: String
        var type: String
    }
}
