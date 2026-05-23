//
//  Split from DirectMLXAgentRuntime.swift
//  MLXCoder
//

import Foundation

func jsonString(from value: Any) -> String {
    AgentJSONSupport.jsonString(from: value)
}

func jsonCompatible(_ value: Any) -> Any {
    AgentJSONSupport.jsonCompatible(value)
}

public extension Dictionary where Key == String, Value == Any {
    public func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key] as? String {
                return value
            }
            if let value = self[key] {
                return String(describing: value)
            }
        }
        return nil
    }

    public func bool(_ keys: String...) -> Bool? {
        for key in keys {
            if let value = self[key] as? Bool {
                return value
            }
            if let value = self[key] as? NSNumber {
                return value.boolValue
            }
            if let value = self[key] as? String {
                switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "true", "yes", "1":
                    return true
                case "false", "no", "0":
                    return false
                default:
                    continue
                }
            }
        }
        return nil
    }

    public func int(_ keys: String...) -> Int? {
        for key in keys {
            if let value = self[key] as? Int {
                return value
            }
            if let value = self[key] as? NSNumber {
                return value.intValue
            }
            if let value = self[key] as? String,
               let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }
        return nil
    }
}
