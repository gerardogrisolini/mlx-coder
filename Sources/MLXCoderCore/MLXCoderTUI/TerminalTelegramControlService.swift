//
//  TerminalTelegramControlService.swift
//  mlx-coder
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TerminalTelegramControlState: Equatable, Sendable {
    public var isConfigured: Bool
    public var isActive: Bool
    public var statusText: String
    public var botUsername: String?
    public var lastError: String?
    public var lastMessagePreview: String?

    public static func inactive(
        settings: AgentTelegramSettingsManifest? = AgentSettingsManifestStore.load()?.telegram
    ) -> Self {
        let isConfigured = settings?.isEnabled == true
        return Self(
            isConfigured: isConfigured,
            isActive: false,
            statusText: isConfigured ? "Configured" : "Not configured",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )
    }
}

public struct TerminalTelegramIncomingMessage: Equatable, Sendable {
    public let chatID: Int64
    public let userID: Int64
    public let text: String?
    public let voice: TerminalTelegramVoiceAttachment?
    public let messageID: Int
    public let chatTitle: String?
    public let username: String?
}

public struct TerminalTelegramVoiceAttachment: Equatable, Sendable {
    public let fileID: String
    public let fileUniqueID: String?
    public let duration: Int?
    public let mimeType: String?
    public let fileSize: Int?
}

public struct TerminalTelegramBotIdentity: Equatable, Sendable {
    public let username: String?
}

public struct TerminalTelegramLinkedChat: Equatable, Sendable {
    public let chatID: Int64
    public let chatTitle: String?
}

public actor TerminalTelegramPairingService {
    private let client: TerminalTelegramAPIClient
    private var lastUpdateID: Int?

    public init(botToken: String) {
        client = TerminalTelegramAPIClient(token: botToken)
    }

    public func prepare() async throws -> TerminalTelegramBotIdentity {
        _ = try? await client.deleteWebhook(dropPendingUpdates: true)
        let bot = try await client.getMe()
        return TerminalTelegramBotIdentity(username: bot.username)
    }

    public func waitForPairing(code: String) async throws -> TerminalTelegramLinkedChat {
        let expectedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while !Task.isCancelled {
            let updates = try await client.getUpdates(
                offset: lastUpdateID.map { $0 + 1 },
                timeout: 30
            )
            for update in updates {
                lastUpdateID = update.updateID
                guard let message = update.message,
                      let text = message.text?.nilIfBlank,
                      let user = message.from,
                      user.isBot != true else {
                    continue
                }

                guard Self.pairingCode(in: text) == expectedCode else {
                    try? await client.sendMessage(
                        "mlx-coder setup is waiting for the pairing code shown in the terminal.",
                        to: message.chat.id
                    )
                    continue
                }

                try? await client.sendMessage(
                    "Telegram linked to mlx-coder.",
                    to: message.chat.id
                )
                return TerminalTelegramLinkedChat(
                    chatID: message.chat.id,
                    chatTitle: message.chat.displayTitle
                )
            }
        }
        throw CancellationError()
    }

    public nonisolated static func pairingCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        )
        guard let firstPart = parts.first else {
            return nil
        }

        let command = String(firstPart).lowercased()
        if command == "/start" || command.hasPrefix("/start@") {
            guard parts.count == 2 else {
                return nil
            }
            return String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }

        return trimmed.uppercased()
    }
}

public actor TerminalTelegramControlService {
    public nonisolated let incomingMessages: AsyncStream<TerminalTelegramIncomingMessage>

    private let incomingContinuation: AsyncStream<TerminalTelegramIncomingMessage>.Continuation
    private var state: TerminalTelegramControlState
    private var pollingTask: Task<Void, Never>?
    private var lastUpdateID: Int?

    public init() {
        var continuation: AsyncStream<TerminalTelegramIncomingMessage>.Continuation!
        incomingMessages = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        incomingContinuation = continuation
        state = TerminalTelegramControlState.inactive()
    }

    deinit {
        pollingTask?.cancel()
    }

    public func currentState() -> TerminalTelegramControlState {
        state
    }

    public func start() async throws -> TerminalTelegramControlState {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let client = TerminalTelegramAPIClient(token: token)

        _ = try? await client.deleteWebhook(dropPendingUpdates: false)
        let bot = try await client.getMe()

        stopPolling()
        state = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: bot.username.map { "Active as @\($0)" } ?? "Active",
            botUsername: bot.username,
            lastError: nil,
            lastMessagePreview: state.lastMessagePreview
        )
        pollingTask = Task { [weak self] in
            await self?.poll(token: token)
        }
        return state
    }

    public func stop() -> TerminalTelegramControlState {
        stopPolling()
        let settings = AgentSettingsManifestStore.load()?.telegram
        state.isConfigured = settings?.isEnabled == true
        state.isActive = false
        state.statusText = state.isConfigured ? "Configured" : "Not configured"
        return state
    }

    public func sendMessage(
        _ text: String,
        to chatID: Int64
    ) async throws -> TerminalTelegramControlState {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }

        try await TerminalTelegramAPIClient(token: token)
            .sendMessage(trimmed, to: chatID)
        state.lastError = nil
        return state
    }

    public func downloadVoiceAudio(
        _ voice: TerminalTelegramVoiceAttachment
    ) async throws -> AgentVoiceAudioInput {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let downloadedFile = try await TerminalTelegramAPIClient(token: token)
            .downloadFile(fileID: voice.fileID)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-coder-telegram-voice-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: downloadedFile.filename))
        try downloadedFile.data.write(to: temporaryURL, options: .atomic)
        return AgentVoiceAudioInput(
            fileURL: temporaryURL,
            filename: downloadedFile.filename,
            contentType: voice.mimeType ?? Self.contentType(for: downloadedFile.filename),
            removeAfterUse: true
        )
    }

    private func telegramSettings() throws -> AgentTelegramSettingsManifest {
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              settings.isConfigured else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return settings
    }

    private func telegramToken(from settings: AgentTelegramSettingsManifest) throws -> String {
        guard let token = settings.botToken?.nilIfBlank else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return token
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(token: String) async {
        let client = TerminalTelegramAPIClient(token: token)
        while !Task.isCancelled {
            do {
                let updates = try await client.getUpdates(
                    offset: lastUpdateID.map { $0 + 1 },
                    timeout: 30
                )
                for update in updates {
                    lastUpdateID = update.updateID
                    handle(update)
                }
                state.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                state.lastError = error.localizedDescription
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handle(_ update: TerminalTelegramUpdate) {
        guard state.isActive,
              let message = update.message,
              let user = message.from,
              user.isBot != true else {
            return
        }

        let text = message.text?.nilIfBlank
        let voice = message.voice.map {
            TerminalTelegramVoiceAttachment(
                fileID: $0.fileID,
                fileUniqueID: $0.fileUniqueID,
                duration: $0.duration,
                mimeType: $0.mimeType,
                fileSize: $0.fileSize
            )
        }
        guard text != nil || voice != nil else {
            return
        }

        state.lastMessagePreview = text ?? "voice message"
        incomingContinuation.yield(
            TerminalTelegramIncomingMessage(
                chatID: message.chat.id,
                userID: user.id,
                text: text,
                voice: voice,
                messageID: message.messageID,
                chatTitle: message.chat.displayTitle,
                username: user.username
            )
        )
    }

    private nonisolated static func contentType(for filename: String) -> String? {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "oga", "ogg":
            return "audio/ogg"
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        default:
            return nil
        }
    }

    private nonisolated static func fileExtension(for filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.nilIfBlank ?? "oga"
    }

}

private struct TerminalTelegramAPIClient: Sendable {
    let token: String

    func getMe() async throws -> TerminalTelegramUser {
        try await request(method: "getMe", body: TerminalTelegramEmptyRequest())
    }

    func deleteWebhook(dropPendingUpdates: Bool) async throws -> Bool {
        try await request(
            method: "deleteWebhook",
            body: TerminalTelegramDeleteWebhookRequest(dropPendingUpdates: dropPendingUpdates)
        )
    }

    func getUpdates(
        offset: Int?,
        timeout: Int
    ) async throws -> [TerminalTelegramUpdate] {
        try await request(
            method: "getUpdates",
            body: TerminalTelegramGetUpdatesRequest(
                offset: offset,
                timeout: timeout,
                allowedUpdates: ["message"]
            )
        )
    }

    func sendMessage(
        _ text: String,
        to chatID: Int64
    ) async throws {
        let request = TerminalTelegramSendMessageRequest(
            chatID: chatID,
            text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000))
        )
        let _: TerminalTelegramMessage = try await self.request(
            method: "sendMessage",
            body: request
        )
    }

    func downloadFile(fileID: String) async throws -> TerminalTelegramDownloadedFile {
        let file: TerminalTelegramFile = try await request(
            method: "getFile",
            body: TerminalTelegramGetFileRequest(fileID: fileID)
        )
        guard let filePath = file.filePath?.nilIfBlank,
              let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)") else {
            throw TerminalTelegramControlError.unexpectedResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TerminalTelegramControlError.unexpectedResponse
        }
        return TerminalTelegramDownloadedFile(
            data: data,
            filename: URL(fileURLWithPath: filePath).lastPathComponent.nilIfBlank
                ?? "telegram-voice.oga"
        )
    }

    func request<Request: Encodable, Response: Decodable>(
        method: String,
        body: Request
    ) async throws -> Response {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TerminalTelegramControlError.invalidToken
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TerminalTelegramControlError.unexpectedResponse
        }

        let decoded = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<Response>.self,
            from: data
        )
        guard (200..<300).contains(httpResponse.statusCode),
              decoded.ok,
              let result = decoded.result else {
            throw TerminalTelegramControlError.httpError(
                httpResponse.statusCode,
                decoded.description ?? String(data: data, encoding: .utf8)
            )
        }
        return result
    }
}

public enum TerminalTelegramControlError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case invalidToken
    case emptyMessage
    case unexpectedResponse
    case httpError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Telegram is not configured. Run mlx-coder --setup and enable Telegram remote control."
        case .invalidToken:
            return "Telegram bot token is invalid."
        case .emptyMessage:
            return "Cannot send an empty Telegram message."
        case .unexpectedResponse:
            return "Telegram returned an unexpected response."
        case let .httpError(statusCode, body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return "Telegram returned HTTP \(statusCode): \(detail)"
            }
            return "Telegram returned HTTP \(statusCode)."
        }
    }
}

private struct TerminalTelegramAPIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
}

private struct TerminalTelegramEmptyRequest: Encodable {}

private struct TerminalTelegramDeleteWebhookRequest: Encodable {
    let dropPendingUpdates: Bool

    enum CodingKeys: String, CodingKey {
        case dropPendingUpdates = "drop_pending_updates"
    }
}

private struct TerminalTelegramGetUpdatesRequest: Encodable {
    let offset: Int?
    let timeout: Int
    let allowedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case offset
        case timeout
        case allowedUpdates = "allowed_updates"
    }
}

private struct TerminalTelegramSendMessageRequest: Encodable {
    let chatID: Int64
    let text: String

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
    }
}

private struct TerminalTelegramGetFileRequest: Encodable {
    let fileID: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
    }
}

private struct TerminalTelegramDownloadedFile: Sendable {
    let data: Data
    let filename: String
}

private struct TerminalTelegramUpdate: Decodable {
    let updateID: Int
    let message: TerminalTelegramMessage?

    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }
}

private struct TerminalTelegramMessage: Decodable {
    let messageID: Int
    let from: TerminalTelegramUser?
    let chat: TerminalTelegramChat
    let text: String?
    let voice: TerminalTelegramVoice?

    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
        case voice
    }
}

private struct TerminalTelegramVoice: Decodable {
    let fileID: String
    let fileUniqueID: String?
    let duration: Int?
    let mimeType: String?
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case duration
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

private struct TerminalTelegramFile: Decodable {
    let fileID: String
    let fileUniqueID: String?
    let fileSize: Int?
    let filePath: String?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileSize = "file_size"
        case filePath = "file_path"
    }
}

private struct TerminalTelegramUser: Decodable {
    let id: Int64
    let isBot: Bool?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case username
    }
}

private struct TerminalTelegramChat: Decodable {
    let id: Int64
    let type: String
    let title: String?
    let username: String?
    let firstName: String?
    let lastName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case username
        case firstName = "first_name"
        case lastName = "last_name"
    }

    var displayTitle: String? {
        title
            ?? username.map { "@\($0)" }
            ?? [firstName, lastName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
                .joined(separator: " ")
                .nilIfBlank
    }
}
