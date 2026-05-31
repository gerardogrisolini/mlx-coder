//
//  main.swift
//  mlx-jira-tools-feature
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(macOS)
import Darwin
import Security
#elseif os(Linux)
import Glibc
#endif
import MLXCoderCore
import MLXFeatureKit

struct JiraSearchTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let query: String?
    }

    typealias Output = String

    static let name = "jira.search"
    static let description = "Searches Jira issues by issue key, issue URL, or text and returns selectable issue summaries."
    static let inputSchema = #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#

    func run(_ input: Input, context _: MLXFeatureContext) async throws -> String {
        guard let query = input.query?.trimmedNonEmpty else {
            throw JiraToolsError.missingArgument("query")
        }

        let service = try JiraRESTService.loadConfigured()
        let issues = try await service.searchIssues(matching: query)
        guard !issues.isEmpty else {
            return "Jira search: \(query)\nNo issues found."
        }
        return JiraToolRenderer.renderSearchResults(issues, query: query)
    }
}

struct JiraReadTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {
        let issueKey: String?
        let issue_key: String?
        let key: String?
        let url: String?
        let query: String?
        let includeRaw: Bool?
        let include_raw: Bool?
    }

    typealias Output = String

    static let name = "jira.read"
    static let description = "Loads a Jira issue and returns task context for the model without creating a local task."
    static let inputSchema = #"{"type":"object","properties":{"issueKey":{"type":"string"},"issue_key":{"type":"string"},"key":{"type":"string"},"url":{"type":"string"},"query":{"type":"string"},"includeRaw":{"type":"boolean"},"include_raw":{"type":"boolean"}}}"#

    func run(_ input: Input, context _: MLXFeatureContext) async throws -> String {
        guard let query = [
            input.issueKey,
            input.issue_key,
            input.key,
            input.url,
            input.query
        ].compactMap({ $0?.trimmedNonEmpty }).first else {
            throw JiraToolsError.missingArgument("issueKey")
        }

        let service = try JiraRESTService.loadConfigured()
        let issue = try await service.loadIssue(matching: query)
        return JiraToolRenderer.renderTaskContext(
            issue,
            includeRaw: input.includeRaw ?? input.include_raw ?? false
        )
    }
}

struct JiraSignOutTool: MLXFeatureTool {
    struct Input: Decodable, Sendable {}
    typealias Output = String

    static let name = "jira.signOut"
    static let description = "Clears the persisted Jira API token used by the Jira tools."
    static let inputSchema = #"{"type":"object","properties":{}}"#

    func run(_: Input, context _: MLXFeatureContext) async throws -> String {
        let configuration = try JiraConfigurationStore.load()
        try JiraCredentialStore.remove(account: configuration.credentialAccount)
        return "Jira credentials cleared. Run `/feature enable mlx-jira-tools` to configure Jira again."
    }
}

@main
struct MLXJiraToolsFeatureMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--setup") {
            let exitCode = await JiraSetupRunner.run()
            terminate(code: exitCode)
        }

        await MLXFeatureRunner.run([
            AnyMLXFeatureTool(JiraSearchTool()),
            AnyMLXFeatureTool(JiraReadTool()),
            AnyMLXFeatureTool(JiraSignOutTool())
        ])
    }

    private static func terminate(code: Int32) -> Never {
        #if canImport(Darwin) || canImport(Glibc)
        exit(code)
        #else
        fatalError("mlx-jira-tools-feature terminated with code \(code).")
        #endif
    }
}

private enum JiraSetupRunner {
    static func run() async -> Int32 {
        do {
            writeLine("Jira setup")
            writeLine("Configure a Jira Cloud site for mlx-coder.")
            writeLine("")

            let currentConfiguration = try? JiraConfigurationStore.load()
            let sitePromptDefault = currentConfiguration?.siteURLString
            guard let rawSiteURL = promptLine(
                "Jira site URL",
                defaultValue: sitePromptDefault,
                required: true
            ) else {
                throw JiraToolsError.invalidConfiguration("Jira site URL is required.")
            }

            let siteURL = try JiraStoredConfiguration.normalizedSiteURL(from: rawSiteURL)
            guard let email = promptLine(
                "Atlassian email",
                defaultValue: currentConfiguration?.email,
                required: true
            ) else {
                throw JiraToolsError.invalidConfiguration("Atlassian email is required.")
            }
            guard let apiToken = promptSecretLine("Atlassian API token", required: true) else {
                throw JiraToolsError.invalidConfiguration("Atlassian API token is required.")
            }

            let configuration = JiraStoredConfiguration(
                siteURLString: siteURL.absoluteString,
                email: email
            )
            let service = JiraRESTService(configuration: configuration, apiToken: apiToken)
            let accountName = try await service.validateCredentials()
            try JiraConfigurationStore.save(configuration)
            try JiraCredentialStore.save(apiToken, account: configuration.credentialAccount)

            writeLine("")
            writeLine("Jira connected: \(siteURL.host ?? siteURL.absoluteString) as \(accountName).")
            return 0
        } catch {
            writeLine("", stderr: true)
            writeLine("mlx-coder: \(error.localizedDescription)", stderr: true)
            return 1
        }
    }

    private static func promptLine(
        _ label: String,
        defaultValue: String? = nil,
        required: Bool = false
    ) -> String? {
        while true {
            let suffix = defaultValue?.trimmedNonEmpty.map { " [\($0)]" } ?? ""
            write("\(label)\(suffix): ")
            let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = value?.isEmpty == false ? value : defaultValue
            if let resolved = resolved?.trimmedNonEmpty {
                return resolved
            }
            guard required else {
                return nil
            }
            writeLine("\(label) is required.")
        }
    }

    private static func promptSecretLine(
        _ label: String,
        required: Bool = false
    ) -> String? {
        #if os(macOS)
        guard isatty(STDIN_FILENO) == 1 else {
            return promptLine(label, required: required)
        }

        while true {
            write("\(label): ")
            var originalAttributes = termios()
            guard tcgetattr(STDIN_FILENO, &originalAttributes) == 0 else {
                return promptLine(label, required: required)
            }

            var hiddenAttributes = originalAttributes
            hiddenAttributes.c_lflag &= ~tcflag_t(ECHO)
            guard tcsetattr(STDIN_FILENO, TCSANOW, &hiddenAttributes) == 0 else {
                return promptLine(label, required: required)
            }
            let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
            var restoreAttributes = originalAttributes
            _ = tcsetattr(STDIN_FILENO, TCSANOW, &restoreAttributes)
            writeLine("")

            if let value = value?.trimmedNonEmpty {
                return value
            }
            guard required else {
                return nil
            }
            writeLine("\(label) is required.")
        }
        #else
        return promptLine(label, required: required)
        #endif
    }
}

private struct JiraStoredConfiguration: Codable, Hashable, Sendable {
    let siteURLString: String
    let email: String

    var siteURL: URL {
        URL(string: siteURLString)!
    }

    var credentialAccount: String {
        "\(siteURL.host ?? siteURLString)|\(email.lowercased())"
    }

    static func normalizedSiteURL(from rawValue: String) throws -> URL {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.localizedCaseInsensitiveContains("://") {
            value = "https://\(value)"
        }

        guard var components = URLComponents(string: value),
              components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw JiraToolsError.invalidConfiguration("Invalid Jira site URL: \(rawValue)")
        }

        components.scheme = components.scheme?.lowercased() ?? "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw JiraToolsError.invalidConfiguration("Invalid Jira site URL: \(rawValue)")
        }
        return url
    }
}

private enum JiraConfigurationStore {
    private static let filename = "jira.json"

    static func load(fileManager: FileManager = .default) throws -> JiraStoredConfiguration {
        let url = configurationURL(fileManager: fileManager)
        guard let data = try? Data(contentsOf: url) else {
            throw JiraToolsError.notConfigured
        }
        do {
            return try JSONDecoder().decode(JiraStoredConfiguration.self, from: data)
        } catch {
            throw JiraToolsError.invalidConfiguration("Invalid jira.json at \(url.path).")
        }
    }

    static func save(
        _ configuration: JiraStoredConfiguration,
        fileManager: FileManager = .default
    ) throws {
        let url = configurationURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        try data.write(to: url, options: [.atomic])
    }

    private static func configurationURL(fileManager: FileManager = .default) -> URL {
        MLXAppStorageDirectory
            .appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(filename)
            .standardizedFileURL
    }
}

private struct JiraIssueSummary: Hashable, Sendable {
    let key: String
    let summary: String
    let status: String?
    let issueType: String?
    let assignee: String?
    let url: URL
}

private struct JiraIssueDetail: Sendable {
    let key: String
    let summary: String
    let status: String?
    let issueType: String?
    let assignee: String?
    let priority: String?
    let url: URL
    let description: String?
    let acceptanceCriteria: [String]
    let designURLs: [String]
    let referenceURLs: [String]
    let notableFields: [(name: String, value: String)]
    let rawPayload: JSONValue
}

private actor JiraRESTService {
    private let configuration: JiraStoredConfiguration
    private let apiToken: String

    init(configuration: JiraStoredConfiguration, apiToken: String) {
        self.configuration = configuration
        self.apiToken = apiToken
    }

    static func loadConfigured() throws -> JiraRESTService {
        let configuration = try JiraConfigurationStore.load()
        let apiToken = try JiraCredentialStore.load(account: configuration.credentialAccount)
        return JiraRESTService(configuration: configuration, apiToken: apiToken)
    }

    func validateCredentials() async throws -> String {
        let result = try await request(
            path: "/rest/api/3/myself",
            queryItems: []
        )
        return result["displayName"]?.stringValue
            ?? result["emailAddress"]?.stringValue
            ?? configuration.email
    }

    func searchIssues(matching query: String) async throws -> [JiraIssueSummary] {
        if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
            let issue = try await fetchIssue(issueKey: issueKey)
            return [JiraIssueParser.summary(from: issue)]
        }

        let result = try await request(
            path: "/rest/api/3/issue/picker",
            queryItems: [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "currentJQL", value: "")
            ]
        )
        let summaries = JiraIssueParser.issueSummaries(
            fromPickerResult: result,
            siteURL: configuration.siteURL
        )
        return Array(summaries.prefix(12))
    }

    func loadIssue(matching query: String) async throws -> JiraIssueDetail {
        if let issueKey = JiraIssueKeyExtractor.issueKey(in: query) {
            return try await fetchIssue(issueKey: issueKey)
        }

        let matches = try await searchIssues(matching: query)
        guard matches.count == 1,
              let issueKey = matches.first?.key else {
            throw JiraToolsError.requestFailed(
                "Jira search returned \(matches.count) issues. Call jira.search first, then call jira.read with the selected issue key."
            )
        }
        return try await fetchIssue(issueKey: issueKey)
    }

    private func fetchIssue(issueKey: String) async throws -> JiraIssueDetail {
        let result = try await request(
            path: "/rest/api/3/issue/\(issueKey)",
            queryItems: [
                URLQueryItem(name: "fields", value: "*all"),
                URLQueryItem(name: "expand", value: "names")
            ]
        )
        guard let detail = JiraIssueParser.issueDetail(
            from: result,
            siteURL: configuration.siteURL
        ) else {
            throw JiraToolsError.issueNotFound(issueKey)
        }
        return detail
    }

    private func request(path: String, queryItems: [URLQueryItem]) async throws -> JSONValue {
        guard var components = URLComponents(url: configuration.siteURL, resolvingAgainstBaseURL: false) else {
            throw JiraToolsError.requestFailed("Unable to build Jira request URL.")
        }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw JiraToolsError.requestFailed("Unable to build Jira request URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JiraToolsError.requestFailed("Invalid Jira response.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw JiraToolsError.requestFailed(
                "Jira request failed with HTTP \(httpResponse.statusCode). \(responseMessage(from: data))"
            )
        }

        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw JiraToolsError.requestFailed("Invalid Jira JSON response.")
        }
    }

    private var authorizationHeader: String {
        let credentials = "\(configuration.email):\(apiToken)"
        return "Basic \(Data(credentials.utf8).base64EncodedString())"
    }

    private func responseMessage(from data: Data) -> String {
        if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            if let message = value["message"]?.stringValue {
                return message
            }
            if let messages = value["errorMessages"]?.arrayValue,
               !messages.isEmpty {
                return messages.compactMap(\.stringValue).joined(separator: " ")
            }
        }
        return String(decoding: data.prefix(400), as: UTF8.self)
    }
}

private enum JiraIssueParser {
    static func issueSummaries(
        fromPickerResult result: JSONValue,
        siteURL: URL
    ) -> [JiraIssueSummary] {
        let sections = result["sections"]?.arrayValue
            ?? result["issueSections"]?.arrayValue
            ?? []
        var summaries: [JiraIssueSummary] = []

        for section in sections {
            for issue in section["issues"]?.arrayValue ?? [] {
                guard let key = issue["key"]?.stringValue?.trimmedNonEmpty else {
                    continue
                }
                let summary = [
                    issue["summaryText"]?.stringValue,
                    issue["summary"]?.flattenedText()
                ].compactMap { $0?.trimmedNonEmpty }.first ?? key
                summaries.append(
                    JiraIssueSummary(
                        key: key,
                        summary: summary,
                        status: issue["status"]?.flattenedText().trimmedNonEmpty,
                        issueType: issue["issuetype"]?.flattenedText().trimmedNonEmpty,
                        assignee: issue["assignee"]?.flattenedText().trimmedNonEmpty,
                        url: browseURL(siteURL: siteURL, key: key)
                    )
                )
            }
        }

        return summaries
    }

    static func issueDetail(from result: JSONValue, siteURL: URL) -> JiraIssueDetail? {
        guard let key = result["key"]?.stringValue?.trimmedNonEmpty,
              let fields = result["fields"]?.objectValue else {
            return nil
        }

        let names = result["names"]?.objectValue ?? [:]
        let summary = fields["summary"]?.stringValue?.trimmedNonEmpty ?? key
        let fieldTexts = fields.compactMap { fieldKey, fieldValue -> (name: String, value: String)? in
            let name = names[fieldKey]?.stringValue?.trimmedNonEmpty ?? fieldKey
            guard let value = fieldValue.flattenedText().trimmedNonEmpty else {
                return nil
            }
            return (name, value)
        }

        let acceptanceCriteria = fieldTexts
            .filter { fieldNameMatches($0.name, tokens: ["acceptance", "criteri", "definition of done"]) }
            .flatMap { splitListItems($0.value) }
            .deduplicated()

        let designURLs = fieldTexts
            .filter { fieldNameMatches($0.name, tokens: ["figma", "design", "dettagli fondamentali", "fundamental details"]) }
            .flatMap { URLs(in: $0.value) }
            .filter { $0.localizedCaseInsensitiveContains("figma") || $0.localizedCaseInsensitiveContains("design") }
            .deduplicated()

        let referenceURLs = fieldTexts
            .flatMap { URLs(in: $0.value) }
            .filter { !$0.localizedCaseInsensitiveContains(siteURL.host ?? "") }
            .deduplicated()

        let notableFields = fieldTexts
            .filter { field in
                fieldNameMatches(
                    field.name,
                    tokens: ["epic", "sprint", "component", "label", "fix version", "story points", "priority"]
                )
            }
            .prefix(12)
            .map { ($0.name, $0.value) }

        return JiraIssueDetail(
            key: key,
            summary: summary,
            status: fields["status"]?["name"]?.stringValue?.trimmedNonEmpty,
            issueType: fields["issuetype"]?["name"]?.stringValue?.trimmedNonEmpty,
            assignee: fields["assignee"]?["displayName"]?.stringValue?.trimmedNonEmpty,
            priority: fields["priority"]?["name"]?.stringValue?.trimmedNonEmpty,
            url: browseURL(siteURL: siteURL, key: key),
            description: fields["description"]?.flattenedText().trimmedNonEmpty,
            acceptanceCriteria: acceptanceCriteria,
            designURLs: designURLs,
            referenceURLs: referenceURLs,
            notableFields: notableFields,
            rawPayload: result
        )
    }

    static func summary(from detail: JiraIssueDetail) -> JiraIssueSummary {
        JiraIssueSummary(
            key: detail.key,
            summary: detail.summary,
            status: detail.status,
            issueType: detail.issueType,
            assignee: detail.assignee,
            url: detail.url
        )
    }

    private static func fieldNameMatches(_ name: String, tokens: [String]) -> Bool {
        let normalized = name.lowercased()
        return tokens.contains { normalized.contains($0.lowercased()) }
    }

    private static func splitListItems(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .flatMap { line -> [String] in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleaned = trimmed
                    .replacingOccurrences(of: #"^\s*[-*•]\s*"#, with: "", options: .regularExpression)
                    .replacingOccurrences(of: #"^\s*\d+[.)]\s*"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? [] : [cleaned]
            }
    }

    private static func URLs(in text: String) -> [String] {
        let pattern = #"https?://[^\s<>)"]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else {
                return nil
            }
            return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        }
    }

    private static func browseURL(siteURL: URL, key: String) -> URL {
        guard var components = URLComponents(url: siteURL, resolvingAgainstBaseURL: false) else {
            return siteURL
        }
        components.path = "/browse/\(key)"
        return components.url ?? siteURL
    }
}

private enum JiraIssueKeyExtractor {
    static func issueKey(in value: String) -> String? {
        let pattern = #"\b([A-Z][A-Z0-9]+-\d+)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range),
              match.numberOfRanges > 1,
              let keyRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[keyRange]).uppercased()
    }
}

private enum JiraToolRenderer {
    static func renderSearchResults(_ issues: [JiraIssueSummary], query: String) -> String {
        var lines = ["Jira search: \(query)", ""]
        for issue in issues {
            var details: [String] = []
            if let issueType = issue.issueType {
                details.append(issueType)
            }
            if let status = issue.status {
                details.append(status)
            }
            if let assignee = issue.assignee {
                details.append("assignee: \(assignee)")
            }
            let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
            lines.append("- \(issue.key): \(issue.summary)\(suffix)")
            lines.append("  \(issue.url.absoluteString)")
        }
        return lines.joined(separator: "\n")
    }

    static func renderTaskContext(_ detail: JiraIssueDetail, includeRaw: Bool) -> String {
        var sections: [String] = []
        var header = [
            "Task context imported from Jira:",
            "",
            "Issue: \(detail.key)",
            "Title: \(detail.summary)",
            "URL: \(detail.url.absoluteString)"
        ]
        appendOptional("Type", detail.issueType, to: &header)
        appendOptional("Status", detail.status, to: &header)
        appendOptional("Assignee", detail.assignee, to: &header)
        appendOptional("Priority", detail.priority, to: &header)
        sections.append(header.joined(separator: "\n"))

        if let description = detail.description {
            sections.append("Description:\n\(description)")
        }
        if !detail.acceptanceCriteria.isEmpty {
            sections.append(
                "Acceptance criteria:\n"
                + detail.acceptanceCriteria.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !detail.designURLs.isEmpty {
            sections.append(
                "Design links:\n"
                + detail.designURLs.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !detail.referenceURLs.isEmpty {
            sections.append(
                "Reference links:\n"
                + detail.referenceURLs.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !detail.notableFields.isEmpty {
            sections.append(
                "Additional fields:\n"
                + detail.notableFields.map { "- \($0.name): \($0.value)" }.joined(separator: "\n")
            )
        }
        if includeRaw {
            sections.append("Raw Jira payload:\n\(detail.rawPayload.prettyPrinted())")
        }
        return sections.joined(separator: "\n\n")
    }

    private static func appendOptional(_ label: String, _ value: String?, to lines: inout [String]) {
        guard let value else {
            return
        }
        lines.append("\(label): \(value)")
    }
}

private enum JiraToolsError: LocalizedError {
    case missingArgument(String)
    case notConfigured
    case invalidConfiguration(String)
    case missingCredentials
    case requestFailed(String)
    case issueNotFound(String)
    case keychain(Int32)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(name):
            return "Missing Jira tool argument: \(name)."
        case .notConfigured:
            return "Jira is not configured. Enable the feature with `/feature enable mlx-jira-tools` to run Jira setup."
        case let .invalidConfiguration(message):
            return message
        case .missingCredentials:
            return "Jira API token was not found. Enable the feature with `/feature enable mlx-jira-tools` to run Jira setup."
        case let .requestFailed(message):
            return message
        case let .issueNotFound(issueKey):
            return "Unable to load Jira issue \(issueKey) from the REST API."
        case let .keychain(status):
            return "Unable to access the Jira API token in Keychain (\(status))."
        }
    }
}

#if os(macOS)
private enum JiraCredentialStore {
    private static let service = "MLXCoder.JiraAPIToken"

    static func load(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            throw JiraToolsError.missingCredentials
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8)?.trimmedNonEmpty else {
            throw JiraToolsError.keychain(status)
        }
        return token
    }

    static func save(_ apiToken: String, account: String) throws {
        let data = Data(apiToken.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw JiraToolsError.keychain(updateStatus)
        }

        var addQuery = baseQuery(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw JiraToolsError.keychain(addStatus)
        }
    }

    static func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw JiraToolsError.keychain(status)
        }
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
#else
private enum JiraCredentialStore {
    static func load(account _: String) throws -> String {
        throw JiraToolsError.invalidConfiguration("Jira credential storage is only available on macOS.")
    }

    static func save(_: String, account _: String) throws {
        throw JiraToolsError.invalidConfiguration("Jira credential storage is only available on macOS.")
    }

    static func remove(account _: String) throws {}
}
#endif

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    func flattenedText() -> String {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return String(format: "%g", value)
        case let .bool(value):
            return value ? "true" : "false"
        case .null:
            return ""
        case let .array(values):
            return values
                .map { $0.flattenedText() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        case let .object(object):
            if let text = object["text"]?.stringValue {
                return text
            }
            if object["type"]?.stringValue == "hardBreak" {
                return "\n"
            }
            if let content = object["content"]?.arrayValue {
                let separator = blockSeparatingTypes.contains(object["type"]?.stringValue ?? "") ? "\n" : " "
                return content
                    .map { $0.flattenedText() }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: separator)
            }
            if let name = object["name"]?.stringValue {
                return name
            }
            if let displayName = object["displayName"]?.stringValue {
                return displayName
            }
            if let value = object["value"]?.stringValue {
                return value
            }
            if let url = object["url"]?.stringValue {
                return url
            }
            return object
                .sorted { $0.key < $1.key }
                .map { $0.value.flattenedText() }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    private var blockSeparatingTypes: Set<String> {
        [
            "paragraph",
            "bulletList",
            "orderedList",
            "listItem",
            "blockquote",
            "heading",
            "panel"
        ]
    }
}

private extension Array where Element == String {
    func deduplicated() -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in self {
            guard let normalized = value.trimmedNonEmpty else {
                continue
            }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                result.append(normalized)
            }
        }
        return result
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private func write(_ string: String, stderr: Bool = false) {
    let data = Data(string.utf8)
    if stderr {
        FileHandle.standardError.write(data)
    } else {
        FileHandle.standardOutput.write(data)
    }
}

private func writeLine(_ string: String, stderr: Bool = false) {
    write(string + "\n", stderr: stderr)
}
