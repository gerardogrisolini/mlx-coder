//
//  MLXThinkingCapability.swift
//  SwiftMLX
//
//  Created by OpenAI on 24/04/26.
//

import Foundation

public nonisolated struct MLXThinkingCapability: Equatable, Sendable {
    public let options: [MLXThinkingSelection]
    public let defaultSelection: MLXThinkingSelection

    public init(
        options: [MLXThinkingSelection],
        defaultSelection: MLXThinkingSelection
    ) {
        self.options = options
        self.defaultSelection = defaultSelection
    }

    public func selection(for rawValue: String?) -> MLXThinkingSelection {
        guard let rawValue,
              let requestedSelection = MLXThinkingSelection(rawValue: rawValue),
              options.contains(requestedSelection) else {
            return defaultSelection
        }

        return requestedSelection
    }
}
