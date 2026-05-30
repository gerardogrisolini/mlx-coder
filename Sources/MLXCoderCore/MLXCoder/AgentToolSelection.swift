//
//  AgentToolSelection.swift
//  MLXCoder
//

import Foundation

public enum AgentToolSelection {
    public static func selectableDescriptors(
        additionalDescriptors: [DirectToolDescriptor] = []
    ) -> [DirectToolDescriptor] {
        DirectToolExecutor.canonicalized(
            DirectToolCatalog.selectableDescriptors
                + SwiftFeatureRuntime.defaultFeatureToolDescriptors(includeDisabled: true)
                + additionalDescriptors
        )
    }
}
