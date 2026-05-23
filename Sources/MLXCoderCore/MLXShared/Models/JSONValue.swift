//
//  JSONValue.swift
//  SwiftMLX
//
//  Created by Gerardo Grisolini on 20/03/26.
//

import Foundation

public nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case object([String: JSONValue])
    case array([JSONValue])
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: encoded())
    }

    public func prettyPrinted() -> String {
        guard let object = try? JSONSerialization.jsonObject(with: encoded()),
              let data = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.withoutEscapingSlashes, .sortedKeys]
              ),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }

    public var stringValue: String? {
        guard case let .string(value) = self else {
            return nil
        }

        return value
    }

    public var numberValue: Double? {
        guard case let .number(value) = self else {
            return nil
        }

        return value
    }

    public var boolValue: Bool? {
        guard case let .bool(value) = self else {
            return nil
        }

        return value
    }

    private func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("null".utf8)
    }
}
