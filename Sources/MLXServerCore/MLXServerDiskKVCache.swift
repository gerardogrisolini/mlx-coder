//
//  MLXServerDiskKVCache.swift
//  mlx-server
//
//  Session-keyed disk persistence for chat KV caches.
//
//  The in-memory KV cache is owned by MLXLMCommon's `ChatSession`; this
//  store only persists each session's cache to disk (one safetensors file
//  per session entry, overwritten in place as the session grows) so a
//  restarted server can rehydrate the session and continue without
//  re-prefilling the transcript.
//

import CryptoKit
import Foundation
import os
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
        MLXServerSettingsStore.supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("KVCaches", isDirectory: true)
            .standardizedFileURL
    }
}

/// Result of restoring a persisted chat session cache from disk.
/// `@unchecked Sendable`: the loaded `[KVCache]` is freshly deserialized
/// from disk and owned exclusively by the requesting generation task.
struct MLXServerDiskChatSessionMatch: @unchecked Sendable {
    var cache: [KVCache]
    var fingerprints: [MLXServerChatTranscriptFingerprint]
    var contextTokenCount: Int?
}

struct MLXServerPersistedChatSessionMetadata: Codable, Sendable {
    var version: Int
    var sessionKey: String
    var modelID: String
    var runtimeKind: String
    var cacheLayoutSignature: String
    var toolsSignature: String
    var contextSignature: String
    var entryKey: String
    var fingerprints: [MLXServerChatTranscriptFingerprint]
    var contextTokenCount: Int?
    var byteCount: Int64
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date

    func matches(
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String
    ) -> Bool {
        version == MLXServerDiskKVCacheStore.metadataVersion
            && sessionKey == key.sessionKey
            && modelID == key.modelID
            && runtimeKind == key.runtimeKind.rawValue
            && cacheLayoutSignature == key.cacheLayoutSignature
            && entryKey == key.entryKey
            && self.toolsSignature == toolsSignature
            && self.contextSignature == contextSignature
    }
}

struct MLXServerDiskKVCachePersistenceTarget: Sendable {
    var cacheURL: URL
    var metadataURL: URL
    var temporaryURL: URL
}

final class MLXServerDiskKVCacheStore: @unchecked Sendable {
    static let metadataVersion = 4

    private let configuration: MLXServerDiskKVCacheConfiguration
    private let fileManager: FileManager
    private let storeLock = OSAllocatedUnfairLock()
    private let ensuredDirectoryLock = OSAllocatedUnfairLock()
    private var ensuredDirectoryPaths = Set<String>()

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

    // MARK: - Load

    /// Restores the persisted cache for a session entry when it can serve
    /// the requested transcript as a strict continuation.
    func loadSession(
        for key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        requestFingerprints: [MLXServerChatTranscriptFingerprint]
    ) -> MLXServerDiskChatSessionMatch? {
        guard configuration.isEnabled else {
            return nil
        }

        let urls = entryURLs(for: key.entryKey, modelID: key.modelID)
        guard let metadata = loadMetadata(from: urls.metadataURL),
              metadata.matches(
                  key: key,
                  toolsSignature: toolsSignature,
                  contextSignature: contextSignature
              ),
              MLXServerChatSessionTranscript.continuationSuffixStartIndex(
                  stored: metadata.fingerprints,
                  request: requestFingerprints
              ) != nil,
              fileManager.fileExists(atPath: urls.cacheURL.path)
        else {
            return nil
        }

        // Heavy safetensors I/O happens outside the store lock so
        // concurrent lookups and persistence are not serialized behind
        // disk reads.
        do {
            let (cache, _) = try loadPromptCache(url: urls.cacheURL)
            guard cache.hasPromptState else {
                removeEntryIfUnchanged(
                    cacheURL: urls.cacheURL,
                    metadataURL: urls.metadataURL,
                    expectedUpdatedAt: metadata.updatedAt
                )
                return nil
            }
            withStoreLock {
                touchEntry(
                    metadata: metadata,
                    cacheURL: urls.cacheURL,
                    metadataURL: urls.metadataURL
                )
            }
            return MLXServerDiskChatSessionMatch(
                cache: cache,
                fingerprints: metadata.fingerprints,
                contextTokenCount: metadata.contextTokenCount ?? cache.contextTokenCount
            )
        } catch {
            removeEntryIfUnchanged(
                cacheURL: urls.cacheURL,
                metadataURL: urls.metadataURL,
                expectedUpdatedAt: metadata.updatedAt
            )
            return nil
        }
    }

    // MARK: - Persist

    /// Returns false when the entry on disk already represents exactly this
    /// transcript, making a rewrite pointless.
    func needsPersistence(
        for key: MLXServerChatSessionCacheKey,
        fingerprints: [MLXServerChatTranscriptFingerprint]
    ) -> Bool {
        guard configuration.isEnabled else {
            return false
        }
        let urls = entryURLs(for: key.entryKey, modelID: key.modelID)
        guard let metadata = loadMetadata(from: urls.metadataURL),
              metadata.entryKey == key.entryKey,
              fileManager.fileExists(atPath: urls.cacheURL.path) else {
            return true
        }
        return metadata.fingerprints != fingerprints
    }

    func preparePersistenceTarget(
        for key: MLXServerChatSessionCacheKey
    ) throws -> MLXServerDiskKVCachePersistenceTarget? {
        try withStoreLock {
            guard configuration.isEnabled else {
                return nil
            }
            let urls = entryURLs(for: key.entryKey, modelID: key.modelID)
            let temporaryURL = urls.cacheURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(key.entryKey).tmp.safetensors")

            try ensureDirectoryExists(urls.cacheURL.deletingLastPathComponent())
            try? fileManager.removeItem(at: temporaryURL)

            return MLXServerDiskKVCachePersistenceTarget(
                cacheURL: urls.cacheURL,
                metadataURL: urls.metadataURL,
                temporaryURL: temporaryURL
            )
        }
    }

    func commitPersistedSession(
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        fingerprints: [MLXServerChatTranscriptFingerprint],
        contextTokenCount: Int? = nil,
        target: MLXServerDiskKVCachePersistenceTarget
    ) throws {
        try withStoreLock {
            try? fileManager.removeItem(at: target.cacheURL)
            try fileManager.moveItem(at: target.temporaryURL, to: target.cacheURL)

            let now = Date()
            let existingMetadata = loadMetadata(from: target.metadataURL)
            let metadata = MLXServerPersistedChatSessionMetadata(
                version: Self.metadataVersion,
                sessionKey: key.sessionKey,
                modelID: key.modelID,
                runtimeKind: key.runtimeKind.rawValue,
                cacheLayoutSignature: key.cacheLayoutSignature,
                toolsSignature: toolsSignature,
                contextSignature: contextSignature,
                entryKey: key.entryKey,
                fingerprints: fingerprints,
                contextTokenCount: contextTokenCount,
                byteCount: byteCount(of: target.cacheURL),
                createdAt: existingMetadata?.createdAt ?? now,
                updatedAt: now,
                lastAccessedAt: now
            )
            saveMetadata(metadata, to: target.metadataURL)
            enforceDiskLimit(preserving: target.cacheURL)
        }
    }

    func discardPersistenceTarget(_ target: MLXServerDiskKVCachePersistenceTarget) {
        withStoreLock {
            try? fileManager.removeItem(at: target.temporaryURL)
        }
    }

    func enforceDiskLimit() {
        withStoreLock {
            enforceDiskLimit(preserving: nil)
        }
    }

    // MARK: - Internals

    private func withStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        storeLock.lock()
        defer {
            storeLock.unlock()
        }
        return try body()
    }

    func entryURLs(
        for entryKey: String,
        modelID: String
    ) -> (cacheURL: URL, metadataURL: URL) {
        let modelDirectory = configuration.directory
            .appendingPathComponent(modelDirectoryName(modelID), isDirectory: true)
        let baseURL = modelDirectory.appendingPathComponent(entryKey)
        return (
            cacheURL: baseURL.appendingPathExtension("safetensors"),
            metadataURL: baseURL.appendingPathExtension("json")
        )
    }

    private func modelDirectoryName(_ modelID: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(modelID.utf8))
        return SHA256.hexString(from: hasher.finalize()).prefix(16).description
    }

    private func loadMetadata(
        from url: URL
    ) -> MLXServerPersistedChatSessionMetadata? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            MLXServerPersistedChatSessionMetadata.self,
            from: data
        )
    }

    private func saveMetadata(
        _ metadata: MLXServerPersistedChatSessionMetadata,
        to url: URL
    ) {
        do {
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(metadata).write(to: url, options: .atomic)
        } catch {
        }
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        let directoryURL = url.standardizedFileURL
        let path = directoryURL.path

        ensuredDirectoryLock.lock()
        let isAlreadyEnsured = ensuredDirectoryPaths.contains(path)
        ensuredDirectoryLock.unlock()

        guard !isAlreadyEnsured else {
            return
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        ensuredDirectoryLock.lock()
        ensuredDirectoryPaths.insert(path)
        ensuredDirectoryLock.unlock()
    }

    /// Minimum interval between on-disk `lastAccessedAt` rewrites. Eviction
    /// tolerates access times that are stale by up to one interval.
    static let accessTimePersistenceInterval: TimeInterval = 15 * 60

    /// Records a cache hit. Must be called while holding the store lock.
    private func touchEntry(
        metadata: MLXServerPersistedChatSessionMetadata,
        cacheURL: URL,
        metadataURL: URL
    ) {
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return
        }
        var touched = metadata
        let now = Date()
        touched.lastAccessedAt = now
        touched.byteCount = byteCount(of: cacheURL)

        let byteCountChanged = touched.byteCount != metadata.byteCount
        let persistedAccessIsStale =
            now.timeIntervalSince(metadata.lastAccessedAt) > Self.accessTimePersistenceInterval
        if byteCountChanged || persistedAccessIsStale {
            saveMetadata(touched, to: metadataURL)
        }
    }

    /// Removes an entry detected as invalid during unlocked disk reads, but
    /// only if it has not been rewritten by a concurrent commit since its
    /// metadata was read.
    private func removeEntryIfUnchanged(
        cacheURL: URL,
        metadataURL: URL,
        expectedUpdatedAt: Date
    ) {
        withStoreLock {
            if let currentMetadata = loadMetadata(from: metadataURL),
               currentMetadata.updatedAt != expectedUpdatedAt {
                return
            }
            removeEntry(cacheURL: cacheURL, metadataURL: metadataURL)
        }
    }

    private func removeEntry(
        cacheURL: URL,
        metadataURL: URL
    ) {
        try? fileManager.removeItem(at: cacheURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    private struct PersistedEntry {
        var metadataURL: URL
        var cacheURL: URL
        var metadata: MLXServerPersistedChatSessionMetadata
    }

    /// Temporary persistence files older than this are considered leftovers
    /// from a crashed or interrupted write and are removed while
    /// enumerating. Recent ones may belong to an in-flight
    /// `savePromptCache`, which runs outside the store lock.
    static let orphanedTemporaryFileMaxAge: TimeInterval = 60 * 60

    private func persistedEntriesFromDisk() -> [PersistedEntry] {
        guard
            fileManager.fileExists(atPath: configuration.directory.path),
            let enumerator = fileManager.enumerator(
                at: configuration.directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var entries: [PersistedEntry] = []
        var cacheFileURLs: [URL] = []
        var referencedCachePaths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "safetensors" {
                cacheFileURLs.append(url)
                continue
            }
            guard url.pathExtension == "json",
                  var metadata = loadMetadata(from: url) else {
                continue
            }

            let cacheURL = url.deletingPathExtension().appendingPathExtension("safetensors")
            guard metadata.version == Self.metadataVersion else {
                removeEntry(cacheURL: cacheURL, metadataURL: url)
                continue
            }

            guard fileManager.fileExists(atPath: cacheURL.path) else {
                try? fileManager.removeItem(at: url)
                continue
            }

            referencedCachePaths.insert(cacheURL.standardizedFileURL.path)
            let currentByteCount = byteCount(of: cacheURL)
            if metadata.byteCount != currentByteCount {
                metadata.byteCount = currentByteCount
                saveMetadata(metadata, to: url)
            }
            entries.append(
                PersistedEntry(
                    metadataURL: url,
                    cacheURL: cacheURL,
                    metadata: metadata
                )
            )
        }

        removeOrphanedCacheFiles(
            cacheFileURLs,
            referencedCachePaths: referencedCachePaths
        )
        return entries
    }

    /// Deletes cache payloads that no metadata references: `.safetensors`
    /// files left behind by a crash between move and metadata write, and
    /// stale `.tmp.safetensors` files from interrupted writes.
    private func removeOrphanedCacheFiles(
        _ cacheFileURLs: [URL],
        referencedCachePaths: Set<String>
    ) {
        for url in cacheFileURLs {
            let standardizedURL = url.standardizedFileURL
            if standardizedURL.deletingPathExtension().pathExtension == "tmp" {
                let modificationDate =
                    (try? fileManager.attributesOfItem(atPath: standardizedURL.path))?[
                        .modificationDate
                    ] as? Date
                let age = Date().timeIntervalSince(modificationDate ?? .distantPast)
                if age > Self.orphanedTemporaryFileMaxAge {
                    try? fileManager.removeItem(at: standardizedURL)
                }
                continue
            }
            if !referencedCachePaths.contains(standardizedURL.path) {
                try? fileManager.removeItem(at: standardizedURL)
            }
        }
    }

    private func enforceDiskLimit(
        preserving preservedCacheURL: URL?
    ) {
        guard let limitBytes = configuration.limitBytes, limitBytes > 0 else {
            return
        }

        let entries = persistedEntriesFromDisk()
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

    private func byteCount(of url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

final class MLXServerDiskKVCachePersistenceWriter: @unchecked Sendable {
    private struct Job: Sendable {
        var operation: @Sendable () async -> Void
    }

    private let lock = OSAllocatedUnfairLock()
    private var pendingJobs: [String: Job] = [:]
    private var pendingKeys: [String] = []
    private var isDraining = false

    func enqueue(
        coalescingKey: String,
        operation: @escaping @Sendable () async -> Void
    ) {
        let job = Job(operation: operation)
        let shouldStartDrain: Bool

        lock.lock()
        if pendingJobs[coalescingKey] == nil {
            pendingKeys.append(coalescingKey)
        }
        pendingJobs[coalescingKey] = job
        if isDraining {
            shouldStartDrain = false
        } else {
            isDraining = true
            shouldStartDrain = true
        }
        lock.unlock()

        guard shouldStartDrain else {
            return
        }

        Task.detached(priority: .utility) { [self] in
            await drain()
        }
    }

    private func drain() async {
        while let job = nextJob() {
            await job.operation()
        }
    }

    private func nextJob() -> Job? {
        lock.lock()
        defer {
            lock.unlock()
        }

        while !pendingKeys.isEmpty {
            let key = pendingKeys.removeFirst()
            if let job = pendingJobs.removeValue(forKey: key) {
                return job
            }
        }

        isDraining = false
        return nil
    }
}

extension Array where Element == KVCache {
    var hasPromptState: Bool {
        let state = flatMap(\.state)
        return !state.isEmpty && state.allSatisfy { $0.size > 0 }
    }

    var contextTokenCount: Int? {
        let offsets = map(\.offset).filter { $0 > 0 }
        return offsets.max()
    }
}
