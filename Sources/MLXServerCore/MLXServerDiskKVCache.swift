//
//  MLXServerDiskKVCache.swift
//  mlx-server
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

struct MLXServerDiskKVCacheIdentity: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind
    var cacheLayoutSignature: String
    var promptTokenDigest: String
    var promptTokenCount: Int
    var promptTokenIDs: [Int]

    init(
        modelID: String,
        runtimeKind: MLXServerModelRuntimeKind,
        cacheLayoutSignature: String,
        promptTokenDigest: String,
        promptTokenCount: Int,
        promptTokenIDs: [Int]
    ) {
        self.modelID = modelID
        self.runtimeKind = runtimeKind
        self.cacheLayoutSignature = cacheLayoutSignature
        self.promptTokenDigest = promptTokenDigest
        self.promptTokenCount = promptTokenCount
        self.promptTokenIDs = promptTokenIDs
    }

    var entryKey: String {
        var hasher = SHA256()
        append("mlx-server-disk-kv-cache-v3", to: &hasher)
        append(modelID, to: &hasher)
        append(runtimeKind.rawValue, to: &hasher)
        append(cacheLayoutSignature, to: &hasher)
        append("prompt-tokens", to: &hasher)
        append(promptTokenDigest, to: &hasher)
        append(String(promptTokenCount), to: &hasher)
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

struct MLXServerDiskKVCachePrefixQuery: Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind
    var cacheLayoutSignature: String
    var promptTokenIDs: [Int]
}

// `@unchecked Sendable`: the loaded `[KVCache]` is freshly deserialized from
// disk and owned exclusively by the requesting generation task.
struct MLXServerDiskKVCachePrefixMatch: @unchecked Sendable {
    var cache: [KVCache]
    var promptTokenCount: Int
    var storedPromptTokenCount: Int
}

final class MLXServerDiskKVCacheStore: @unchecked Sendable {
    fileprivate static let metadataVersion = 3
    private let configuration: MLXServerDiskKVCacheConfiguration
    private let fileManager: FileManager
    private let indexRebuildObserver: (@Sendable () -> Void)?
    private let storeLock = OSAllocatedUnfairLock()
    private let ensuredDirectoryLock = OSAllocatedUnfairLock()
    private var ensuredDirectoryPaths = Set<String>()

    // MARK: - In-memory index

    /// Lazily-built in-memory index of all persisted entries on disk.
    /// Avoids enumerating the filesystem on every call to
    /// `loadLongestPromptPrefix` or `enforceDiskLimit`.
    private var entriesIndex: [DiskCacheEntryIndexKey: [MLXServerPersistedDiskKVCacheEntry]]?

    private struct DiskCacheEntryIndexKey: Hashable {
        var modelID: String
        var runtimeKind: String
        var cacheLayoutSignature: String
    }

    private func diskCacheEntries() -> [MLXServerPersistedDiskKVCacheEntry] {
        entriesIndex?.values.flatMap { $0 } ?? []
    }

    private func diskCacheEntries(
        modelID: String,
        runtimeKind: String,
        cacheLayoutSignature: String
    ) -> [MLXServerPersistedDiskKVCacheEntry] {
        let key = DiskCacheEntryIndexKey(
            modelID: modelID,
            runtimeKind: runtimeKind,
            cacheLayoutSignature: cacheLayoutSignature
        )
        return entriesIndex?[key] ?? []
    }

    private func rebuildIndexIfNeeded() {
        guard entriesIndex == nil else { return }
        rebuildIndex()
    }

    private func rebuildIndex() {
        indexRebuildObserver?()
        var index: [DiskCacheEntryIndexKey: [MLXServerPersistedDiskKVCacheEntry]] = [:]
        for entry in persistedEntriesFromDisk() {
            index[indexKey(for: entry.metadata), default: []].append(entry)
        }
        entriesIndex = index
    }

    private func indexKey(
        for metadata: MLXServerPersistedDiskKVCacheMetadata
    ) -> DiskCacheEntryIndexKey {
        DiskCacheEntryIndexKey(
            modelID: metadata.modelID,
            runtimeKind: metadata.runtimeKind,
            cacheLayoutSignature: metadata.cacheLayoutSignature
        )
    }

    private func upsertIndexedEntry(
        _ entry: MLXServerPersistedDiskKVCacheEntry
    ) {
        guard entriesIndex != nil else {
            return
        }

        // Same model/runtime/layout entries always share one index bucket,
        // so the stale-entry removal can stay scoped to that bucket.
        removeIndexedEntry(
            cacheURL: entry.cacheURL,
            metadataURL: entry.metadataURL,
            entryKey: entry.metadata.entryKey,
            scopedTo: indexKey(for: entry.metadata)
        )
        entriesIndex?[indexKey(for: entry.metadata), default: []].append(entry)
    }

    private func removeIndexedEntry(
        cacheURL: URL,
        metadataURL: URL,
        entryKey: String? = nil,
        scopedTo scopedKey: DiskCacheEntryIndexKey? = nil
    ) {
        guard entriesIndex != nil else {
            return
        }

        let standardizedCacheURL = cacheURL.standardizedFileURL
        let standardizedMetadataURL = metadataURL.standardizedFileURL
        let keys: [DiskCacheEntryIndexKey]
        if let scopedKey {
            keys = entriesIndex?[scopedKey] != nil ? [scopedKey] : []
        } else {
            keys = entriesIndex.map { Array($0.keys) } ?? []
        }
        for key in keys {
            entriesIndex?[key]?.removeAll { entry in
                entry.cacheURL.standardizedFileURL == standardizedCacheURL
                    || entry.metadataURL.standardizedFileURL == standardizedMetadataURL
                    || entry.metadata.entryKey == entryKey
            }
            if entriesIndex?[key]?.isEmpty == true {
                entriesIndex?[key] = nil
            }
        }
    }

    init(
        configuration: MLXServerDiskKVCacheConfiguration,
        fileManager: FileManager = .default,
        indexRebuildObserver: (@Sendable () -> Void)? = nil
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        self.indexRebuildObserver = indexRebuildObserver
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
            let metadata = loadMetadata(from: urls.metadataURL),
            metadata.matches(identity),
            fileManager.fileExists(atPath: urls.cacheURL.path)
        else {
            return nil
        }

        // Heavy safetensors I/O happens outside the store lock so concurrent
        // lookups and persistence are not serialized behind disk reads.
        do {
            let (cache, _) = try loadPromptCache(url: urls.cacheURL)
            guard cache.hasPromptState,
                  normalizePromptCacheLength(cache, expectedTokenCount: metadata.promptTokenCount)
            else {
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
            return cache
        } catch {
            removeEntryIfUnchanged(
                cacheURL: urls.cacheURL,
                metadataURL: urls.metadataURL,
                expectedUpdatedAt: metadata.updatedAt
            )
            return nil
        }
    }

        func loadLongestPromptPrefix(
        for query: MLXServerDiskKVCachePrefixQuery
    ) -> MLXServerDiskKVCachePrefixMatch? {
        guard configuration.isEnabled, !query.promptTokenIDs.isEmpty else {
            return nil
        }

        // Only index consultation happens under the store lock; the heavy
        // safetensors reads below run unlocked so concurrent lookups and
        // persistence are not serialized behind disk I/O.
        let candidates = withStoreLock { () -> [MLXServerDiskKVCachePrefixCandidate] in
            rebuildIndexIfNeeded()
            return diskCacheEntries(
                modelID: query.modelID,
                runtimeKind: query.runtimeKind.rawValue,
                cacheLayoutSignature: query.cacheLayoutSignature
            )
                .compactMap { entry -> MLXServerDiskKVCachePrefixCandidate? in
                    entry.metadata.reusablePromptPrefixCandidate(
                        for: query,
                        cacheURL: entry.cacheURL,
                        metadataURL: entry.metadataURL
                    )
                }
                .sorted { lhs, rhs in
                    if lhs.reusablePromptTokenCount != rhs.reusablePromptTokenCount {
                        return lhs.reusablePromptTokenCount > rhs.reusablePromptTokenCount
                    }
                    return lhs.metadata.lastAccessedAt > rhs.metadata.lastAccessedAt
                }
        }

        for candidate in candidates {
            do {
                let (cache, _) = try loadPromptCache(url: candidate.cacheURL)
                guard cache.hasPromptState else {
                    removeEntryIfUnchanged(for: candidate)
                    continue
                }
                guard normalizePromptCacheLength(
                    cache,
                    expectedTokenCount: candidate.storedPromptTokenCount
                ) else {
                    removeEntryIfUnchanged(for: candidate)
                    continue
                }
                let tokensToTrim = candidate.storedPromptTokenCount - candidate.reusablePromptTokenCount
                if tokensToTrim > 0 {
                    let trimmedTokenCount = trimPromptPrefixCache(cache, numTokens: tokensToTrim)
                    guard trimmedTokenCount == tokensToTrim else {
                        continue
                    }
                }
                guard cache.hasPromptState else {
                    continue
                }
                guard normalizePromptCacheLength(
                    cache,
                    expectedTokenCount: candidate.reusablePromptTokenCount
                ) else {
                    continue
                }

                withStoreLock {
                    touchEntry(
                        metadata: candidate.metadata,
                        cacheURL: candidate.cacheURL,
                        metadataURL: candidate.metadataURL
                    )
                }
                return MLXServerDiskKVCachePrefixMatch(
                    cache: cache,
                    promptTokenCount: candidate.reusablePromptTokenCount,
                    storedPromptTokenCount: candidate.storedPromptTokenCount
                )
            } catch {
                removeEntryIfUnchanged(for: candidate)
            }
        }

        return nil
    }

    func preparePersistenceTarget(
        for identity: MLXServerDiskKVCacheIdentity
    ) throws -> MLXServerDiskKVCachePersistenceTarget? {
        try withStoreLock {
            guard configuration.isEnabled else {
                return nil
            }
            let urls = entryURLs(for: identity)
            let temporaryURL = urls.cacheURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(identity.entryKey).tmp.safetensors")

            try ensureDirectoryExists(urls.cacheURL.deletingLastPathComponent())
            try? fileManager.removeItem(at: temporaryURL)

            return MLXServerDiskKVCachePersistenceTarget(
                cacheURL: urls.cacheURL,
                metadataURL: urls.metadataURL,
                temporaryURL: temporaryURL
            )
        }
    }

    func commitPersistedCache(
        identity: MLXServerDiskKVCacheIdentity,
        target: MLXServerDiskKVCachePersistenceTarget
    ) throws {
        try withStoreLock {
            try? fileManager.removeItem(at: target.cacheURL)
            try fileManager.moveItem(at: target.temporaryURL, to: target.cacheURL)

            let now = Date()
            let existingMetadata = loadMetadata(from: target.metadataURL)
            let metadata = MLXServerPersistedDiskKVCacheMetadata(
                version: Self.metadataVersion,
                modelID: identity.modelID,
                runtimeKind: identity.runtimeKind.rawValue,
                cacheLayoutSignature: identity.cacheLayoutSignature,
                promptTokenDigest: identity.promptTokenDigest,
                promptTokenCount: identity.promptTokenCount,
                promptTokenIDs: identity.promptTokenIDs,
                entryKey: identity.entryKey,
                byteCount: byteCount(of: target.cacheURL),
                createdAt: existingMetadata?.createdAt ?? now,
                updatedAt: now,
                lastAccessedAt: now
            )
            saveMetadata(metadata, to: target.metadataURL)
            rebuildIndexIfNeeded()
            upsertIndexedEntry(
                MLXServerPersistedDiskKVCacheEntry(
                    metadataURL: target.metadataURL,
                    cacheURL: target.cacheURL,
                    metadata: metadata
                )
            )
            removeEntriesSuperseded(by: metadata, preserving: target.cacheURL)
            enforceDiskLimit(preserving: target.cacheURL)
        }
    }

    /// Removes entries whose prompt is a strict prefix of a newly committed
    /// entry. Such entries are dominated: any query that could reuse them
    /// reuses at least as much from the new entry. Pruning them at commit
    /// keeps long sessions from accumulating near-identical multi-GB
    /// snapshots, one per turn, until LRU eviction kicks in.
    private func removeEntriesSuperseded(
        by metadata: MLXServerPersistedDiskKVCacheMetadata,
        preserving preservedCacheURL: URL
    ) {
        let supersededEntries = diskCacheEntries(
            modelID: metadata.modelID,
            runtimeKind: metadata.runtimeKind,
            cacheLayoutSignature: metadata.cacheLayoutSignature
        ).filter { entry in
            entry.metadata.entryKey != metadata.entryKey
                && entry.cacheURL.standardizedFileURL != preservedCacheURL.standardizedFileURL
                && entry.metadata.promptTokenCount < metadata.promptTokenCount
                && entry.metadata.promptTokenCount == entry.metadata.promptTokenIDs.count
                && metadata.promptTokenIDs.starts(with: entry.metadata.promptTokenIDs)
        }
        for entry in supersededEntries {
            removeEntry(cacheURL: entry.cacheURL, metadataURL: entry.metadataURL)
        }
    }

    func discardPersistenceTarget(_ target: MLXServerDiskKVCachePersistenceTarget) {
        withStoreLock {
            try? fileManager.removeItem(at: target.temporaryURL)
        }
    }

    /// Returns false when an entry already on disk makes writing this
    /// identity pointless: either the exact same entry, or one whose prompt
    /// extends it (any query that could reuse this identity reuses at least
    /// as much from the longer entry). This is the content-addressed dedup
    /// step: aligned store boundaries make repeated turns produce identical
    /// identities, which are skipped here instead of rewritten.
    func needsPersistence(
        for identity: MLXServerDiskKVCacheIdentity
    ) -> Bool {
        withStoreLock {
            guard configuration.isEnabled else {
                return false
            }
            rebuildIndexIfNeeded()
            let isDominated = diskCacheEntries(
                modelID: identity.modelID,
                runtimeKind: identity.runtimeKind.rawValue,
                cacheLayoutSignature: identity.cacheLayoutSignature
            ).contains { entry in
                entry.metadata.promptTokenCount >= identity.promptTokenCount
                    && entry.metadata.promptTokenCount == entry.metadata.promptTokenIDs.count
                    && entry.metadata.promptTokenIDs.starts(with: identity.promptTokenIDs)
            }
            return !isDominated
        }
    }

    func persistCache(
        identity: MLXServerDiskKVCacheIdentity,
        cache: [KVCache]
    ) {
        guard needsPersistence(for: identity) else {
            return
        }
        guard let target = try? preparePersistenceTarget(for: identity) else {
            return
        }

        do {
            try savePromptCache(url: target.temporaryURL, cache: cache)
            try commitPersistedCache(identity: identity, target: target)
        } catch {
            discardPersistenceTarget(target)
        }
    }

    func enforceDiskLimit() {
        withStoreLock {
            enforceDiskLimit(preserving: nil)
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) rethrows -> T {
        storeLock.lock()
        defer {
            storeLock.unlock()
        }
        return try body()
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
            try ensureDirectoryExists(url.deletingLastPathComponent())
            let encoder = JSONEncoder()
            // No pretty-printing: promptTokenIDs can hold tens of thousands
            // of integers and compact output keeps metadata files small.
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

    private func enforceDiskLimit(
        preserving preservedCacheURL: URL?
    ) {
        guard let limitBytes = configuration.limitBytes, limitBytes > 0 else {
            return
        }

        rebuildIndexIfNeeded()
        let entries = diskCacheEntries()
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

    /// Temporary persistence files older than this are considered leftovers
    /// from a crashed or interrupted write and are removed during index
    /// rebuilds. Recent ones may belong to an in-flight `savePromptCache`,
    /// which runs outside the store lock.
    fileprivate static let orphanedTemporaryFileMaxAge: TimeInterval = 60 * 60

    private func persistedEntriesFromDisk() -> [MLXServerPersistedDiskKVCacheEntry] {
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

        var entries: [MLXServerPersistedDiskKVCacheEntry] = []
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
                MLXServerPersistedDiskKVCacheEntry(
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
    /// stale `.tmp.safetensors` files from interrupted writes. Without this
    /// they would occupy disk space invisible to `enforceDiskLimit`.
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

    /// Minimum interval between on-disk `lastAccessedAt` rewrites. The
    /// in-memory index is always updated; the metadata file (which carries
    /// the full promptTokenIDs and can be large) is only rewritten when the
    /// payload size changed or the persisted access time is older than this.
    /// Eviction tolerates access times that are stale by up to one interval.
    fileprivate static let accessTimePersistenceInterval: TimeInterval = 15 * 60

    /// Records a cache hit: refreshes the in-memory index immediately and
    /// rewrites the metadata file only when meaningful. Must be called while
    /// holding the store lock.
    private func touchEntry(
        metadata: MLXServerPersistedDiskKVCacheMetadata,
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
        upsertIndexedEntry(
            MLXServerPersistedDiskKVCacheEntry(
                metadataURL: metadataURL,
                cacheURL: cacheURL,
                metadata: touched
            )
        )
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

    private func removeEntryIfUnchanged(
        for candidate: MLXServerDiskKVCachePrefixCandidate
    ) {
        removeEntryIfUnchanged(
            cacheURL: candidate.cacheURL,
            metadataURL: candidate.metadataURL,
            expectedUpdatedAt: candidate.metadata.updatedAt
        )
    }

    private func removeEntry(
        cacheURL: URL,
        metadataURL: URL
    ) {
        try? fileManager.removeItem(at: cacheURL)
        try? fileManager.removeItem(at: metadataURL)
        removeIndexedEntry(cacheURL: cacheURL, metadataURL: metadataURL)
    }

    private func byteCount(of url: URL) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

final class MLXServerDiskKVCachePersistenceWriter: @unchecked Sendable {
    private struct Job: Sendable {
        var operation: @Sendable () -> Void
    }

    private let lock = OSAllocatedUnfairLock()
    private var pendingJobs: [String: Job] = [:]
    private var pendingKeys: [String] = []
    private var isDraining = false

    func enqueue(
        coalescingKey: String,
        operation: @escaping @Sendable () -> Void
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
            drain()
        }
    }

    private func drain() {
        while let job = nextJob() {
            job.operation()
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

private enum SHA256Digest {
    static func hexString<D: Sequence>(
        from digest: D
    ) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

private extension Array where Element == KVCache {
    var hasPromptState: Bool {
        let state = flatMap(\.state)
        return !state.isEmpty && state.allSatisfy { $0.size > 0 }
    }
}

@discardableResult
private func trimPromptPrefixCache(_ cache: [KVCache], numTokens: Int) -> Int {
    trimPromptCache(cache, numTokens: numTokens)
}

@discardableResult
func normalizePromptCacheLength(
    _ cache: [KVCache],
    expectedTokenCount: Int
) -> Bool {
    guard expectedTokenCount > 0,
          cache.hasPromptState,
          let firstOffset = cache.first?.offset,
          cache.allSatisfy({ $0.offset == firstOffset }) else {
        return false
    }

    if firstOffset == expectedTokenCount {
        return true
    }
    guard firstOffset > expectedTokenCount else {
        return false
    }

    let tokensToTrim = firstOffset - expectedTokenCount
    guard trimPromptPrefixCache(cache, numTokens: tokensToTrim) == tokensToTrim else {
        return false
    }
    return cache.allSatisfy { $0.offset == expectedTokenCount }
}

private struct MLXServerPersistedDiskKVCacheEntry {
    var metadataURL: URL
    var cacheURL: URL
    var metadata: MLXServerPersistedDiskKVCacheMetadata
}

private struct MLXServerDiskKVCachePrefixCandidate {
    var cacheURL: URL
    var metadataURL: URL
    var metadata: MLXServerPersistedDiskKVCacheMetadata
    var reusablePromptTokenCount: Int
    var storedPromptTokenCount: Int
}

struct MLXServerDiskKVCachePersistenceTarget {
    var cacheURL: URL
    var metadataURL: URL
    var temporaryURL: URL
}

private struct MLXServerPersistedDiskKVCacheMetadata: Codable {
    private static let minimumReusablePromptPrefixTokenCount = 256

    var version: Int
    var modelID: String
    var runtimeKind: String
    var cacheLayoutSignature: String
    var promptTokenDigest: String
    var promptTokenCount: Int
    var promptTokenIDs: [Int]
    var entryKey: String
    var byteCount: Int64
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date

    func matches(_ identity: MLXServerDiskKVCacheIdentity) -> Bool {
        guard version == MLXServerDiskKVCacheStore.metadataVersion,
              modelID == identity.modelID,
              runtimeKind == identity.runtimeKind.rawValue,
              cacheLayoutSignature == identity.cacheLayoutSignature,
              entryKey == identity.entryKey else {
            return false
        }

        return promptTokenDigest == identity.promptTokenDigest
            && promptTokenCount == identity.promptTokenCount
    }

    func reusablePromptPrefixCandidate(
        for query: MLXServerDiskKVCachePrefixQuery,
        cacheURL: URL,
        metadataURL: URL
    ) -> MLXServerDiskKVCachePrefixCandidate? {
        guard version == MLXServerDiskKVCacheStore.metadataVersion,
              modelID == query.modelID,
              runtimeKind == query.runtimeKind.rawValue,
              cacheLayoutSignature == query.cacheLayoutSignature,
              promptTokenCount == promptTokenIDs.count,
              promptTokenCount > 0,
              query.promptTokenIDs.count > 1 else {
            return nil
        }

        let commonPrefixTokenCount = promptTokenIDs.commonPrefixCount(
            with: query.promptTokenIDs
        )
        let reusablePromptTokenCount = min(
            commonPrefixTokenCount,
            query.promptTokenIDs.count - 1
        )
        guard reusablePromptTokenCount >= Self.minimumReusablePromptPrefixTokenCount else {
            return nil
        }

        return MLXServerDiskKVCachePrefixCandidate(
            cacheURL: cacheURL,
            metadataURL: metadataURL,
            metadata: self,
            reusablePromptTokenCount: reusablePromptTokenCount,
            storedPromptTokenCount: promptTokenCount
        )
    }
}

private extension Array where Element == Int {
    func commonPrefixCount(with other: [Int]) -> Int {
        let limit = Swift.min(count, other.count)
        var index = 0
        while index < limit, self[index] == other[index] {
            index += 1
        }
        return index
    }
}
