//
//  SwiftFeatureToolRuntime.swift
//  MLXCoder
//

import Foundation

public actor SwiftFeatureRuntime {
    public static let featurePackageToolsAllowedName = "feature.tools"
    public static let generatedSwiftToolsVersion = "6.3"

    public static func isFeatureManagementToolName(_ toolName: String) -> Bool {
        switch toolName {
        case "feature.list",
             "feature.enable",
             "feature.disable",
             "feature.delete",
             "feature.reload",
             "feature.validate",
             "feature.build",
             "feature.scaffold",
             "feature.install":
            return true
        default:
            return false
        }
    }

    let explicitFeatures: [SwiftFeatureBundle]?
    let featureSearchRoots: [URL]?
    let fileManager: FileManager
    var features: [SwiftFeatureBundle]
    var runtimeDiscoveredToolsByFeatureID: [String: [ToolDescriptor]] = [:]

    public init(
        features explicitFeatures: [SwiftFeatureBundle]? = nil,
        featureSearchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) {
        self.explicitFeatures = explicitFeatures
        self.featureSearchRoots = featureSearchRoots
        self.fileManager = fileManager
        if let explicitFeatures {
            self.features = explicitFeatures
        } else {
            self.features = Self.defaultFeatureBundles(
                searchRoots: featureSearchRoots,
                fileManager: fileManager
            )
        }
    }
}
