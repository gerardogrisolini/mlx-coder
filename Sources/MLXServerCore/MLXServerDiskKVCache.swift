//
//  MLXServerDiskKVCache.swift
//  mlx-server
//

import CryptoKit
import Foundation
import MLXLMCommon

public struct MLXServerDiskKVCacheConfiguration: Sendable, Equatable {
    public static let defaultLimitBytes: Int64 = 100 * 1024 * 1024 * 1024

    public var isEnabled: Bool
    public var directory: URL
    public var limitBytes: Int64?

    public init(
        isEnabled: Bool = true,
        directory: URL? = nil,
        limitBytes: Int64? = Self.defaultLimitBytes
    ) {
        self.isEnabled = isEnabled
        self.directory = directory ?? Self.defaultDirectory()
        self.limitBytes = limitBytes
    }

    public static var disabled: Self {
        Self(isEnabled: false, limitBytes: nil)
    }

    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory

        return baseDirectory
            .appendingPathComponent("mlx-server", isDirectory: true)
            .appendingPathComponent("KVCaches", isDirectory: true)
    }
}

struct MLXServerDiskKVCacheIdentity: Hashable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind
    var chatKeySignature: String
    var transcriptSignature: String
    var cacheLayoutSignature: String

    var entryKey: String {
        var hasher = SHA256()
        append("mlx-server-disk-kv-cache-v1", to: &hasher)
        append(modelID, to: &hasher)
        append(runtimeKind.rawValue, to: &hasher)
        append(chatKeySignature, to: &hasher)
        append(transcriptSignature, to: &hasher)
        append(cacheLayoutSignature, to: &hasher)
        return Self.hexString(from: hasher.finalize())
    }

    private static func hexString<D: Sequence>(
        from digest: D
    ) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func append(
        _ value: String,
        to hasher: inout SHA256
    ) {
        let data = Data(value.utf8)
        var count = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &count) { rawBuffer in
            hasher.update(data: Data(rawBuffer))
        }
        hasher.update(data: data)
    }
}

final class MLXServerDiskKVCacheStore {
    fileprivate static let metadataVersion = 1
    private let configuration: MLXServerDiskKVCacheConfiguration
    private let fileManager: FileManager

    init(
        configuration: MLXServerDiskKVCacheConfiguration,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
    }

    var isEnabled: Bool {
        configuration.isEnabled
    }

    func loadCache(
        for identity: MLXServerDiskKVCacheIdentity
    ) -> [KVCache]? {
        guard configuration.isEnabled else {
            return nil
        }

        let urls = entryURLs(for: identity)
        guard
            var metadata = loadMetadata(from: urls.metadataURL),
            metadata.matches(identity),
            fileManager.fileExists(atPath: urls.cacheURL.path)
        else {
            return nil
        }

        do {
            let (cache, _) = try loadPromptCache(url: urls.cacheURL)
            metadata.lastAccessedAt = Date()
            metadata.byteCount = byteCount(of: urls.cacheURL)
            saveMetadata(metadata, to: urls.metadataURL)
            return cache
        } catch {
            removeEntry(cacheURL: urls.cacheURL, metadataURL: urls.metadataURL)
            return nil
        }
    }

    func preparePersistenceTarget(
        for identity: MLXServerDiskKVCacheIdentity
    ) throws -> MLXServerDiskKVCachePersistenceTarget? {
        guard configuration.isEnabled else {
            return nil
        }
        let urls = entryURLs(for: identity)
        let temporaryURL = urls.cacheURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(identity.entryKey).tmp.safetensors")

        try fileManager.createDirectory(
            at: urls.cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? fileManager.removeItem(at: temporaryURL)

        return MLXServerDiskKVCachePersistenceTarget(
            cacheURL: urls.cacheURL,
            metadataURL: urls.metadataURL,
            temporaryURL: temporaryURL
        )
    }

    func commitPersistedCache(
        identity: MLXServerDiskKVCacheIdentity,
        target: MLXServerDiskKVCachePersistenceTarget
    ) throws {
        try? fileManager.removeItem(at: target.cacheURL)
        try fileManager.moveItem(at: target.temporaryURL, to: target.cacheURL)

        let now = Date()
        let existingMetadata = loadMetadata(from: target.metadataURL)
        let metadata = MLXServerPersistedDiskKVCacheMetadata(
            version: Self.metadataVersion,
            modelID: identity.modelID,
            runtimeKind: identity.runtimeKind.rawValue,
            chatKeySignature: identity.chatKeySignature,
            transcriptSignature: identity.transcriptSignature,
            cacheLayoutSignature: identity.cacheLayoutSignature,
            entryKey: identity.entryKey,
            byteCount: byteCount(of: target.cacheURL),
            createdAt: existingMetadata?.createdAt ?? now,
            updatedAt: now,
            lastAccessedAt: now
        )
        saveMetadata(metadata, to: target.metadataURL)
        enforceDiskLimit(preserving: target.cacheURL)
    }

    func discardPersistenceTarget(_ target: MLXServerDiskKVCachePersistenceTarget) {
        try? fileManager.removeItem(at: target.temporaryURL)
    }

    func enforceDiskLimit() {
        enforceDiskLimit(preserving: nil)
    }

    private func entryURLs(
        for identity: MLXServerDiskKVCacheIdentity
    ) -> (cacheURL: URL, metadataURL: URL) {
        let modelDirectory = configuration.directory
            .appendingPathComponent(modelDirectoryName(identity.modelID), isDirectory: true)
        let baseURL = modelDirectory.appendingPathComponent(identity.entryKey)
        return (
            cacheURL: baseURL.appendingPathExtension("safetensors"),
            metadataURL: baseURL.appendingPathExtension("json")
        )
    }

    private func modelDirectoryName(_ modelID: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(modelID.utf8))
        return SHA256Digest.hexString(from: hasher.finalize()).prefix(16).description
    }

    private func loadMetadata(
        from url: URL
    ) -> MLXServerPersistedDiskKVCacheMetadata? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(MLXServerPersistedDiskKVCacheMetadata.self, from: data)
    }

    private func saveMetadata(
        _ metadata: MLXServerPersistedDiskKVCacheMetadata,
        to url: URL
    ) {
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(metadata).write(to: url, options: .atomic)
        } catch {
        }
    }

    private func enforceDiskLimit(
        preserving preservedCacheURL: URL?
    ) {
        guard let limitBytes = configuration.limitBytes, limitBytes > 0 else {
            return
        }

        let entries = persistedEntries()
        let totalByteCount = entries.reduce(Int64(0)) { partial, entry in
            partial + max(entry.metadata.byteCount, 0)
        }
        guard totalByteCount > limitBytes else {
            return
        }

        let targetByteCount = max(Int64(0), limitBytes * 4 / 5)
        var runningByteCount = totalByteCount
        let evictionCandidates = entries
            .filter { entry in
                guard let preservedCacheURL else {
                    return true
                }
                return entry.cacheURL.standardizedFileURL != preservedCacheURL.standardizedFileURL
            }
            .sorted { lhs, rhs in
                if lhs.metadata.lastAccessedAt != rhs.metadata.lastAccessedAt {
                    return lhs.metadata.lastAccessedAt < rhs.metadata.lastAccessedAt
                }
                if lhs.metadata.updatedAt != rhs.metadata.updatedAt {
                    return lhs.metadata.updatedAt < rhs.metadata.updatedAt
                }
                return lhs.metadata.entryKey < rhs.metadata.entryKey
            }

        for entry in evictionCandidates where runningByteCount > targetByteCount {
            runningByteCount -= max(entry.metadata.byteCount, 0)
            removeEntry(cacheURL: entry.cacheURL, metadataURL: entry.metadataURL)
        }
    }

    private func persistedEntries() -> [MLXServerPersistedDiskKVCacheEntry] {
        guard
            fileManager.fileExists(atPath: configuration.directory.path),
            let enumerator = fileManager.enumerator(
                at: configuration.directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var entries: [MLXServerPersistedDiskKVCacheEntry] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "json",
                  var metadata = loadMetadata(from: url),
                  metadata.version == Self.metadataVersion else {
                continue
            }

            let cacheURL = url.deletingPathExtension().appendingPathExtension("safetensors")
            guard fileManager.fileExists(atPath: cacheURL.path) else {
                try? fileManager.removeItem(at: url)
                continue
            }

            let currentByteCount = byteCount(of: cacheURL)
            if metadata.byteCount != currentByteCount {
                metadata.byteCount = currentByteCount
                saveMetadata(metadata, to: url)
            }
            entries.append(
                MLXServerPersistedDiskKVCacheEntry(
                    metadataURL: url,
                    cacheURL: cacheURL,
                    metadata: metadata
                )
            )
        }
        return entries
    }

    private func removeEntry(
        cacheURL: URL,
        metadataURL: URL
    ) {
        try? fileManager.removeItem(at: cacheURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    private func byteCount(of url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private enum SHA256Digest {
    static func hexString<D: Sequence>(
        from digest: D
    ) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct MLXServerPersistedDiskKVCacheEntry {
    var metadataURL: URL
    var cacheURL: URL
    var metadata: MLXServerPersistedDiskKVCacheMetadata
}

struct MLXServerDiskKVCachePersistenceTarget {
    var cacheURL: URL
    var metadataURL: URL
    var temporaryURL: URL
}

private struct MLXServerPersistedDiskKVCacheMetadata: Codable {
    var version: Int
    var modelID: String
    var runtimeKind: String
    var chatKeySignature: String
    var transcriptSignature: String
    var cacheLayoutSignature: String
    var entryKey: String
    var byteCount: Int64
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date

    func matches(_ identity: MLXServerDiskKVCacheIdentity) -> Bool {
        version == MLXServerDiskKVCacheStore.metadataVersion
            && modelID == identity.modelID
            && runtimeKind == identity.runtimeKind.rawValue
            && chatKeySignature == identity.chatKeySignature
            && transcriptSignature == identity.transcriptSignature
            && cacheLayoutSignature == identity.cacheLayoutSignature
            && entryKey == identity.entryKey
    }
}
