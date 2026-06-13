//
//  MLXServerHuggingFaceCachePermissionRequester.swift
//  mlx-coder
//

import Foundation
import MLXServerCore

#if os(macOS)
import AppKit
#endif

enum MLXServerHuggingFaceCachePermissionRequester {
    @MainActor
    static func ensureAccessIfNeeded() async throws {
        let store = MLXServerHuggingFaceCacheAccessStore.shared
        if await store.activatePersistedAccess() != nil,
           MLXServerHuggingFaceCacheAccessStore.hasReadWriteAccess() {
            return
        }
        if MLXServerHuggingFaceCacheAccessStore.hasReadWriteAccess() {
            return
        }

        #if os(macOS)
        let cacheDirectory = MLXServerHuggingFaceCacheAccessStore.cacheDirectory
        FileHandle.standardError.writeString(
            """
            mlx-coder --mlx needs permission to read and write the Hugging Face model cache.

            Directory:
            \(cacheDirectory.path)

            """
        )

        guard let selectedURL = requestAccess(for: cacheDirectory) else {
            throw MLXServerHuggingFaceCachePermissionError.accessNotGranted(cacheDirectory.path)
        }

        try await store.saveAccess(for: selectedURL)
        guard MLXServerHuggingFaceCacheAccessStore.hasReadWriteAccess() else {
            throw MLXServerHuggingFaceCachePermissionError.accessNotGranted(cacheDirectory.path)
        }
        #else
        throw MLXServerHuggingFaceCachePermissionError.accessNotGranted(
            MLXServerHuggingFaceCacheAccessStore.cacheDirectory.path
        )
        #endif
    }

    #if os(macOS)
    @MainActor
    private static func requestAccess(for cacheDirectory: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Authorize Hugging Face Cache"
        panel.message = "Authorize the Hugging Face model cache used by mlx-coder --mlx."
        panel.prompt = "Authorize"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true

        let parentURL = cacheDirectory.deletingLastPathComponent()
        if parentURL.path.isEmpty || parentURL.path == cacheDirectory.path {
            panel.directoryURL = cacheDirectory
        } else {
            panel.directoryURL = parentURL
            panel.nameFieldStringValue = cacheDirectory.lastPathComponent
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url?.standardizedFileURL
    }
    #endif
}

enum MLXServerHuggingFaceCachePermissionError: LocalizedError {
    case accessNotGranted(String)

    var errorDescription: String? {
        switch self {
        case let .accessNotGranted(path):
            return "Hugging Face cache access was not granted for \(path)."
        }
    }
}
