//
//  MLXAttachmentModel.swift
//  SwiftMLX
//
//  Shared attachment primitives for mlx-coder and mlx-server UI.
//

import Foundation
import UniformTypeIdentifiers

public enum MLXAttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case video

    public var symbolName: String {
        switch self {
        case .image:
            return "photo"
        case .video:
            return "film"
        }
    }

    public var title: String {
        switch self {
        case .image:
            return "Image"
        case .video:
            return "Video"
        }
    }
}

public enum MLXAttachmentPlacement: String, Codable, CaseIterable, Sendable {
    case prompt
    case response
}

public struct MLXAttachmentModel: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: MLXAttachmentKind
    public var placement: MLXAttachmentPlacement
    public var contentType: String?
    public var originalFilename: String
    public var payload: Data
    public var byteCount: Int
    public var sortIndex: Int

    public init(
        id: UUID = UUID(),
        kind: MLXAttachmentKind,
        placement: MLXAttachmentPlacement = .prompt,
        contentType: String? = nil,
        originalFilename: String,
        payload: Data,
        byteCount: Int? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.placement = placement
        self.contentType = contentType
        self.originalFilename = originalFilename
        self.payload = payload
        self.byteCount = byteCount ?? payload.count
        self.sortIndex = sortIndex
    }

    public var fileURL: URL? {
        try? MLXAttachmentStore.temporaryFileURL(for: self)
    }
}

public enum MLXAttachmentStoreError: LocalizedError {
    case unsupportedFileType(URL)
    case unreadableFile(URL)
    case cacheDirectoryUnavailable

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(url):
            return "Unsupported attachment type: \(url.lastPathComponent)"
        case let .unreadableFile(url):
            return "Unable to read attachment data from \(url.lastPathComponent)."
        case .cacheDirectoryUnavailable:
            return "Unable to access the app attachment cache directory."
        }
    }
}

public enum MLXAttachmentStore {
    private static let legacyDirectoryName = "Attachments"
    private static let transientDirectoryName = "TransientAttachments"

    public static func importFiles(from urls: [URL]) throws -> [MLXAttachmentModel] {
        var importedAttachments: [MLXAttachmentModel] = []
        importedAttachments.reserveCapacity(urls.count)

        for url in urls {
            importedAttachments.append(try importFile(from: url))
        }

        return importedAttachments
    }

    public static func importFile(from sourceURL: URL) throws -> MLXAttachmentModel {
        let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let kind = try attachmentKind(for: sourceURL)
        guard let payload = try? Data(contentsOf: sourceURL) else {
            throw MLXAttachmentStoreError.unreadableFile(sourceURL)
        }

        let contentType = resolvedContentTypeIdentifier(for: sourceURL)

        return MLXAttachmentModel(
            kind: kind,
            placement: .prompt,
            contentType: contentType,
            originalFilename: sourceURL.lastPathComponent,
            payload: payload,
            byteCount: payload.count,
            sortIndex: 0
        )
    }

    public static func temporaryFileURL(for attachment: MLXAttachmentModel) throws -> URL {
        try temporaryFileURL(
            id: attachment.id,
            originalFilename: attachment.originalFilename,
            contentType: attachment.contentType,
            payload: attachment.payload
        )
    }

    public static func removeLegacyFiles() {
        let fileManager = FileManager.default
        if let legacyDirectory = try? legacyDirectoryURL(),
           fileManager.fileExists(atPath: legacyDirectory.path) {
            try? fileManager.removeItem(at: legacyDirectory)
        }

        if let transientDirectory = try? transientDirectoryURL(),
           fileManager.fileExists(atPath: transientDirectory.path) {
            try? fileManager.removeItem(at: transientDirectory)
        }
    }

    private static func temporaryFileURL(
        id: UUID,
        originalFilename: String,
        contentType: String?,
        payload: Data
    ) throws -> URL {
        let directory = try transientDirectoryURL()
        let fileExtension = preferredFilenameExtension(
            originalFilename: originalFilename,
            contentType: contentType
        )
        let filename = fileExtension.isEmpty
            ? id.uuidString
            : "\(id.uuidString).\(fileExtension)"
        let fileURL = directory.appending(path: filename)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: fileURL.path)
            || ((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) != payload.count) {
            try payload.write(to: fileURL, options: .atomic)
        }

        return fileURL
    }

    private static func attachmentKind(for sourceURL: URL) throws -> MLXAttachmentKind {
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey])
        if let contentType = resourceValues?.contentType {
            if contentType.conforms(to: .image) {
                return .image
            }

            if contentType.conforms(to: .movie) || contentType.conforms(to: .video) {
                return .video
            }
        }

        if let inferredType = UTType(filenameExtension: sourceURL.pathExtension.lowercased()) {
            if inferredType.conforms(to: .image) {
                return .image
            }

            if inferredType.conforms(to: .movie) || inferredType.conforms(to: .video) {
                return .video
            }
        }

        throw MLXAttachmentStoreError.unsupportedFileType(sourceURL)
    }

    private static func resolvedContentTypeIdentifier(for sourceURL: URL) -> String? {
        let resourceValues = try? sourceURL.resourceValues(forKeys: [.contentTypeKey])
        if let identifier = resourceValues?.contentType?.identifier {
            return identifier
        }

        return UTType(filenameExtension: sourceURL.pathExtension.lowercased())?.identifier
    }

    private static func preferredFilenameExtension(
        originalFilename: String,
        contentType: String?
    ) -> String {
        let originalExtension = URL(fileURLWithPath: originalFilename).pathExtension
        if !originalExtension.isEmpty {
            return originalExtension
        }

        if let contentType,
           let preferredExtension = UTType(contentType)?.preferredFilenameExtension {
            return preferredExtension
        }

        return ""
    }

    private static func legacyDirectoryURL() throws -> URL {
        guard let applicationSupportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw MLXAttachmentStoreError.cacheDirectoryUnavailable
        }

        return applicationSupportDirectory.appending(path: legacyDirectoryName)
    }

    private static func transientDirectoryURL() throws -> URL {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw MLXAttachmentStoreError.cacheDirectoryUnavailable
        }

        let directory = cachesDirectory.appending(path: transientDirectoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
