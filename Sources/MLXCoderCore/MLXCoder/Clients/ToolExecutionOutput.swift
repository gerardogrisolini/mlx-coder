//
//  ToolExecutionOutput.swift
//  SwiftMLX
//
//  Created by Codex on 02/05/26.
//

import Foundation

public struct ToolExecutionOutput: Sendable {
    public let text: String
    public let rawResult: JSONValue?

    public init(
        text: String,
        rawResult: JSONValue?
    ) {
        self.text = text
        self.rawResult = rawResult
    }
}
