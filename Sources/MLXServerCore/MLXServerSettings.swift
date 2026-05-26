//
//  MLXServerSettings.swift
//  mlx-server
//

import Foundation

public struct MLXServerSettings: Codable, Equatable, Sendable {
    public var host: String
    public var port: Int
    public var loadOneModelAtATime: Bool
    public var http2PriorKnowledge: Bool
    public var tlsCertificatePath: String?
    public var tlsPrivateKeyPath: String?
    public var metricsLogPath: String?
    public var diskKVCache: MLXServerDiskKVCacheSettings
    public var huggingFaceCache: MLXServerHuggingFaceCacheSettings

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case loadOneModelAtATime = "load_one_model_at_a_time"
        case http2PriorKnowledge = "http2_prior_knowledge"
        case tlsCertificatePath = "tls_certificate_path"
        case tlsPrivateKeyPath = "tls_private_key_path"
        case metricsLogPath = "metrics_log_path"
        case diskKVCache = "disk_kv_cache"
        case huggingFaceCache = "huggingface_cache"
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        loadOneModelAtATime: Bool = true,
        http2PriorKnowledge: Bool = false,
        tlsCertificatePath: String? = nil,
        tlsPrivateKeyPath: String? = nil,
        metricsLogPath: String? = nil,
        diskKVCache: MLXServerDiskKVCacheSettings = .init(),
        huggingFaceCache: MLXServerHuggingFaceCacheSettings = .init()
    ) {
        self.host = host
        self.port = port
        self.loadOneModelAtATime = loadOneModelAtATime
        self.http2PriorKnowledge = http2PriorKnowledge
        self.tlsCertificatePath = tlsCertificatePath
        self.tlsPrivateKeyPath = tlsPrivateKeyPath
        self.metricsLogPath = metricsLogPath
        self.diskKVCache = diskKVCache
        self.huggingFaceCache = huggingFaceCache
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8080
        loadOneModelAtATime = try container.decodeIfPresent(
            Bool.self,
            forKey: .loadOneModelAtATime
        ) ?? true
        http2PriorKnowledge = try container.decodeIfPresent(
            Bool.self,
            forKey: .http2PriorKnowledge
        ) ?? false
        tlsCertificatePath = try container.decodeIfPresent(String.self, forKey: .tlsCertificatePath)
        tlsPrivateKeyPath = try container.decodeIfPresent(String.self, forKey: .tlsPrivateKeyPath)
        metricsLogPath = try container.decodeIfPresent(String.self, forKey: .metricsLogPath)
        diskKVCache = try container.decodeIfPresent(
            MLXServerDiskKVCacheSettings.self,
            forKey: .diskKVCache
        ) ?? .init()
        huggingFaceCache = try container.decodeIfPresent(
            MLXServerHuggingFaceCacheSettings.self,
            forKey: .huggingFaceCache
        ) ?? .init()
    }

    public func validated() throws -> Self {
        let configuration = try MLXServerConfiguration(host: host, port: port).validated()
        let normalizedTLSCertificatePath = tlsCertificatePath?.trimmedNonEmpty
        let normalizedTLSPrivateKeyPath = tlsPrivateKeyPath?.trimmedNonEmpty
        if (normalizedTLSCertificatePath == nil) != (normalizedTLSPrivateKeyPath == nil) {
            throw MLXServerSettingsError.incompleteTLSConfiguration
        }

        return Self(
            host: configuration.host,
            port: configuration.port,
            loadOneModelAtATime: loadOneModelAtATime,
            http2PriorKnowledge: http2PriorKnowledge,
            tlsCertificatePath: normalizedTLSCertificatePath,
            tlsPrivateKeyPath: normalizedTLSPrivateKeyPath,
            metricsLogPath: metricsLogPath?.trimmedNonEmpty,
            diskKVCache: try diskKVCache.validated(),
            huggingFaceCache: huggingFaceCache.validated()
        )
    }

    public var serverConfiguration: MLXServerConfiguration {
        MLXServerConfiguration(host: host, port: port)
    }

    public var modelRetentionPolicy: MLXServerModelRetentionPolicy {
        loadOneModelAtATime ? .unloadPreviousModel : .keepLoadedModels
    }
}

public struct MLXServerHuggingFaceCacheSettings: Codable, Equatable, Sendable {
    public var directoryPath: String?
    public var bookmark: String?

    private enum CodingKeys: String, CodingKey {
        case directoryPath = "directory_path"
        case bookmark
    }

    public init(
        directoryPath: String? = nil,
        bookmark: String? = nil
    ) {
        self.directoryPath = directoryPath
        self.bookmark = bookmark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directoryPath = try container.decodeIfPresent(String.self, forKey: .directoryPath)
        bookmark = try container.decodeIfPresent(String.self, forKey: .bookmark)
    }

    public func validated() -> Self {
        Self(
            directoryPath: directoryPath?.trimmedNonEmpty,
            bookmark: bookmark?.trimmedNonEmpty
        )
    }

    public var bookmarkData: Data? {
        guard let bookmark else {
            return nil
        }
        return Data(base64Encoded: bookmark)
    }
}

public struct MLXServerDiskKVCacheSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var directoryPath: String?
    public var limitGB: Double?

    private enum CodingKeys: String, CodingKey {
        case enabled
        case directoryPath = "directory_path"
        case limitGB = "limit_gb"
    }

    public init(
        enabled: Bool = true,
        directoryPath: String? = nil,
        limitGB: Double? = 100
    ) {
        self.enabled = enabled
        self.directoryPath = directoryPath
        self.limitGB = limitGB
    }

    public func validated() throws -> Self {
        let normalizedDirectoryPath = directoryPath?.trimmedNonEmpty
        if let limitGB, limitGB < 0 {
            throw MLXServerSettingsError.invalidDiskKVCacheLimit
        }
        return Self(
            enabled: enabled,
            directoryPath: normalizedDirectoryPath,
            limitGB: limitGB
        )
    }

    public var configuration: MLXServerDiskKVCacheConfiguration {
        guard enabled else {
            return .disabled
        }

        let directory = directoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let limitBytes = limitGB.map { gb in
            Int64(gb * 1024 * 1024 * 1024)
        }

        return MLXServerDiskKVCacheConfiguration(
            directory: directory,
            limitBytes: limitBytes ?? MLXServerDiskKVCacheConfiguration.defaultLimitBytes
        )
    }
}

public enum MLXServerSettingsStore {
    public static let settingsFilename = "settings.json"

    public static func settingsURL(fileManager: FileManager = .default) -> URL {
        supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }

    public static func supportDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let executableDirectory = executableDirectoryURL(fileManager: fileManager),
           !isAppBundleExecutableDirectory(executableDirectory) {
            return executableDirectory
        }

        #if os(Linux)
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".mlx-server", isDirectory: true)
            .standardizedFileURL
        #else
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return baseDirectory
            .appendingPathComponent("mlx-server", isDirectory: true)
            .standardizedFileURL
        #endif
    }

    public static func loadRequired(
        from url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) throws -> MLXServerSettings {
        guard fileManager.fileExists(atPath: url.path) else {
            throw MLXServerSettingsError.missingSettings(url)
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(MLXServerSettings.self, from: data).validated()
    }

    public static func save(
        _ settings: MLXServerSettings,
        to url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(try settings.validated())
        try data.write(to: url, options: [.atomic])
    }

    public static func loadOrDefault(
        from url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) -> MLXServerSettings {
        (try? loadRequired(from: url, fileManager: fileManager)) ?? MLXServerSettings()
    }

    public static func saveHuggingFaceCacheAccess(
        cacheDirectoryPath: String,
        bookmarkData: Data?,
        fileManager: FileManager = .default
    ) throws {
        var settings = loadOrDefault(fileManager: fileManager)
        settings.huggingFaceCache = MLXServerHuggingFaceCacheSettings(
            directoryPath: cacheDirectoryPath,
            bookmark: bookmarkData?.base64EncodedString()
        )
        try save(settings, fileManager: fileManager)
    }

    public static func clearHuggingFaceCacheAccess(
        fileManager: FileManager = .default
    ) {
        var settings = loadOrDefault(fileManager: fileManager)
        settings.huggingFaceCache = MLXServerHuggingFaceCacheSettings()
        try? save(settings, fileManager: fileManager)
    }

    private static func executableDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            Bundle.main.executableURL,
            CommandLine.arguments.first.map { URL(fileURLWithPath: $0) }
        ].compactMap { $0 }

        for candidate in candidates {
            let directory = candidate
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .standardizedFileURL
                .resolvingSymlinksInPath()

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            return directory
        }

        return nil
    }

    private static func isAppBundleExecutableDirectory(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3 else {
            return false
        }
        return components.suffix(3).dropFirst().elementsEqual(["Contents", "MacOS"])
    }
}

public enum MLXServerSettingsError: LocalizedError, Equatable, Sendable {
    case missingSettings(URL)
    case incompleteTLSConfiguration
    case invalidDiskKVCacheLimit

    public var errorDescription: String? {
        switch self {
        case .missingSettings(let url):
            return "settings.json not found at \(url.path). Run mlx-server --setup first."
        case .incompleteTLSConfiguration:
            return "TLS requires both certificate and private key paths."
        case .invalidDiskKVCacheLimit:
            return "Disk KV cache limit must be greater than or equal to 0 GB."
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
