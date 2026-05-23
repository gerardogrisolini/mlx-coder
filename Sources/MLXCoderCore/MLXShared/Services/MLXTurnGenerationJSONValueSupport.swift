//
//  MLXTurnGenerationJSONValueSupport.swift
//  SwiftMLX
//
//  Created by Gerardo Grisolini on 12/04/26.
//

import Foundation

extension JSONValue {
    public var mlxObjectValue: [String: JSONValue]? {
        guard case let .object(value) = self else {
            return nil
        }
        return value
    }

    public var mlxArrayValue: [JSONValue]? {
        guard case let .array(value) = self else {
            return nil
        }
        return value
    }
}
