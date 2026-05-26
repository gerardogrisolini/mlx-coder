//
//  ACPJSONValueSupport.swift
//  mlx-coder
//

import Foundation

extension JSONValue {
    public static func acpValue(from value: Any?) -> JSONValue {
        guard let value else {
            return .null
        }
        if value is NSNull {
            return .null
        }
        if let jsonValue = value as? JSONValue {
            return jsonValue
        }
        if let string = value as? String {
            return .string(string)
        }
        if let bool = value as? Bool {
            return .bool(bool)
        }
        if let int = value as? Int {
            return .number(Double(int))
        }
        if let int64 = value as? Int64 {
            return .number(Double(int64))
        }
        if let double = value as? Double {
            return .number(double)
        }
        if let float = value as? Float {
            return .number(Double(float))
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let array = value as? [Any] {
            return .array(array.map { JSONValue.acpValue(from: $0) })
        }
        if let object = value as? [String: Any] {
            return .object(object.mapValues { JSONValue.acpValue(from: $0) })
        }
        return .string(String(describing: value))
    }

    public static func acpRequestID(from value: Any?) -> JSONValue? {
        guard let value else {
            return nil
        }
        return acpValue(from: value)
    }

    public var acpStringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }
        return value
    }

    public var acpJSONObject: Any {
        switch self {
        case let .string(value):
            return value
        case let .number(value):
            return value
        case let .object(value):
            return value.mapValues(\.acpJSONObject)
        case let .array(value):
            return value.map(\.acpJSONObject)
        case let .bool(value):
            return value
        case .null:
            return NSNull()
        }
    }
}
