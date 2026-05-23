//
//  MLXThinkingConfiguration+MetadataDetection.swift
//  SwiftMLX
//
//  Created by OpenAI on 24/04/26.
//

import Foundation

extension MLXModelThinkingSupport {
    public static func effortLevels(
        from selections: [MLXThinkingSelection]
    ) -> [MLXThinkingSelection] {
        let requestedLevels = Set(selections)
        return [.minimal, .low, .medium, .high, .xhigh].filter {
            requestedLevels.contains($0)
        }
    }

    public struct MetadataDetector {
        public var supportsThinking = false
        public var supportsEffort = false
        public var supportsPreserveThinking = false
        public var effortLevels: [MLXThinkingSelection] = []

        public var support: MLXModelThinkingSupport? {
            guard supportsThinking else {
                return nil
            }

            if supportsEffort {
                return .effort(
                    levels: effortLevels,
                    supportsPreserveThinking: supportsPreserveThinking
                )
            }

            return MLXModelThinkingSupport(
                supportsThinking: true,
                supportsReasoningEffort: false,
                supportsPreserveThinking: supportsPreserveThinking,
                availableSelections: [.enabled, .off],
                defaultSelection: .enabled
            )
        }

        public mutating func scan(
            _ value: Any,
            keyPath: [String] = []
        ) {
            guard !(value is NSNull) else {
                return
            }

            if let dictionary = value as? [String: Any] {
                for (key, nestedValue) in dictionary {
                    scanKey(key, value: nestedValue, keyPath: keyPath)
                    scan(nestedValue, keyPath: keyPath + [key])
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    scan(item, keyPath: keyPath)
                }
                return
            }

            if let string = value as? String {
                scanString(string, keyPath: keyPath)
                return
            }

            if let number = value as? NSNumber,
               number.boolValue,
               keyPath.contains(where: isThinkingKey) {
                supportsThinking = true
            }
        }

        private mutating func scanKey(
            _ key: String,
            value: Any,
            keyPath: [String]
        ) {
            let normalizedKey = normalizedToken(key)

            if isThinkingKey(normalizedKey), truthy(value) {
                supportsThinking = true
            }

            if isEffortKey(normalizedKey), truthy(value) {
                supportsThinking = true
                supportsEffort = true
                appendEffortLevels(from: value)
            }

            if isPreserveThinkingKey(normalizedKey), truthy(value) {
                supportsThinking = true
                supportsPreserveThinking = true
            }

            if normalizedKey == "supportedparameters"
                || normalizedKey == "supportedparams"
                || normalizedKey == "capabilities"
                || normalizedKey == "features" {
                scanCapabilityList(value)
            }

            if normalizedKey == "chattemplate",
               let template = value as? String,
               template.localizedCaseInsensitiveContains("enable_thinking") {
                supportsThinking = true
            }

            if normalizedKey == "chattemplate",
               let template = value as? String,
               containsPreserveThinkingReference(template) {
                supportsThinking = true
                supportsPreserveThinking = true
            }

            if isModelIdentifierKey(normalizedKey) {
                scanModelIdentifier(value)
            }

            if isThinkingKey(normalizedKey) {
                appendExplicitEffortLevels(from: value)
            }
        }

        private mutating func scanModelIdentifier(
            _ value: Any
        ) {
            if let string = value as? String {
                if isKnownThinkingModelIdentifier(string) {
                    supportsThinking = true
                }
                return
            }

            if let strings = value as? [String] {
                for string in strings where isKnownThinkingModelIdentifier(string) {
                    supportsThinking = true
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    scanModelIdentifier(item)
                }
            }
        }

        private mutating func scanCapabilityList(
            _ value: Any
        ) {
            if let strings = value as? [String] {
                for string in strings {
                    scanCapabilityString(string)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    if let string = item as? String {
                        scanCapabilityString(string)
                    } else {
                        scan(item)
                    }
                }
                return
            }

            if let dictionary = value as? [String: Any] {
                for (key, nestedValue) in dictionary {
                    let normalizedKey = normalizedToken(key)
                    if isThinkingKey(normalizedKey), truthy(nestedValue) {
                        supportsThinking = true
                    }
                    if isEffortKey(normalizedKey), truthy(nestedValue) {
                        supportsThinking = true
                        supportsEffort = true
                        appendEffortLevels(from: nestedValue)
                    }
                    if isPreserveThinkingKey(normalizedKey), truthy(nestedValue) {
                        supportsThinking = true
                        supportsPreserveThinking = true
                    }
                    scan(nestedValue, keyPath: [key])
                }
            }
        }

        private mutating func scanCapabilityString(
            _ string: String
        ) {
            let normalizedString = normalizedToken(string)
            if normalizedString == "reasoning" {
                supportsThinking = true
                supportsEffort = true
            } else if normalizedString.contains("reasoning")
                || normalizedString.contains("thinking")
                || normalizedString.contains("enablethinking") {
                supportsThinking = true
            }

            if normalizedString.contains("preservethinking") {
                supportsThinking = true
                supportsPreserveThinking = true
            }

            if normalizedString.contains("effort") {
                supportsThinking = true
                supportsEffort = true
            }

            appendEffortLevel(from: string)
        }

        private mutating func scanString(
            _ string: String,
            keyPath: [String]
        ) {
            if keyPath.contains(where: isEffortKey) {
                supportsThinking = true
                supportsEffort = true
                appendEffortLevel(from: string)
            }

            if keyPath.contains(where: isThinkingKey),
               truthy(string) {
                supportsThinking = true
            }

            if containsEnableThinkingReference(string) {
                supportsThinking = true
            }

            if containsPreserveThinkingReference(string) {
                supportsThinking = true
                supportsPreserveThinking = true
            }
        }

        private mutating func appendEffortLevels(
            from value: Any
        ) {
            if let string = value as? String {
                appendEffortLevel(from: string)
                return
            }

            if let strings = value as? [String] {
                for string in strings {
                    appendEffortLevel(from: string)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    appendEffortLevels(from: item)
                }
                return
            }

            if truthy(value) {
                supportsEffort = true
            }
        }

        private mutating func appendExplicitEffortLevels(
            from value: Any
        ) {
            if let string = value as? String {
                appendEffortLevel(from: string)
                return
            }

            if let strings = value as? [String] {
                for string in strings {
                    appendEffortLevel(from: string)
                }
                return
            }

            if let array = value as? [Any] {
                for item in array {
                    appendExplicitEffortLevels(from: item)
                }
            }
        }

        private mutating func appendEffortLevel(
            from value: String
        ) {
            let normalizedValue = normalizedToken(value)
            let selection: MLXThinkingSelection?
            if normalizedValue == "max" {
                selection = .xhigh
            } else if normalizedValue == "none" {
                selection = nil
            } else {
                selection = MLXThinkingSelection(rawValue: normalizedValue)
            }

            guard let selection,
                  [.minimal, .low, .medium, .high, .xhigh].contains(selection),
                  !effortLevels.contains(selection) else {
                return
            }

            supportsThinking = true
            supportsEffort = true
            effortLevels.append(selection)
        }

        private func isThinkingKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "reasoning"
                || normalizedKey == "thinking"
                || normalizedKey == "enablethinking"
                || normalizedKey == "reasoningcontent"
                || normalizedKey == "reasoningdetails"
        }

        private func isEffortKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "effort"
                || normalizedKey == "efforts"
                || normalizedKey == "reasoningeffort"
                || normalizedKey == "reasoningefforts"
                || normalizedKey == "thinkingeffort"
                || normalizedKey == "thinkingefforts"
                || normalizedKey == "effortlevels"
                || normalizedKey == "reasoningeffortlevels"
        }

        private func isPreserveThinkingKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "preservethinking"
        }

        private func isModelIdentifierKey(
            _ key: String
        ) -> Bool {
            let normalizedKey = normalizedToken(key)
            return normalizedKey == "id"
                || normalizedKey == "model"
                || normalizedKey == "modelid"
                || normalizedKey == "name"
                || normalizedKey == "modeltype"
                || normalizedKey == "architectures"
                || normalizedKey == "architecture"
        }

        private func isKnownThinkingModelIdentifier(
            _ value: String
        ) -> Bool {
            let normalizedValue = normalizedToken(value)
            return normalizedValue.contains("qwen3")
                || normalizedValue.contains("qwq")
                || normalizedValue.contains("gemma4")
                || normalizedValue.contains("reasoning")
                || normalizedValue.contains("thinking")
                || normalizedValue.contains("deepseekr1")
                || normalizedValue.contains("gptoss")
                || normalizedValue.contains("nemotron3super")
                || normalizedValue.contains("nemotron3ultra")
                || normalizedValue.contains("nemotron3nano")
        }

        private func containsPreserveThinkingReference(
            _ value: String
        ) -> Bool {
            normalizedToken(value).contains("preservethinking")
        }

        private func containsEnableThinkingReference(
            _ value: String
        ) -> Bool {
            normalizedToken(value).contains("enablethinking")
        }

        private func truthy(
            _ value: Any
        ) -> Bool {
            if let bool = value as? Bool {
                return bool
            }

            if let number = value as? NSNumber {
                return number.boolValue
            }

            if let string = value as? String {
                let normalizedString = normalizedToken(string)
                return normalizedString == "true"
                    || normalizedString == "enabled"
                    || normalizedString == "supported"
                    || normalizedString == "yes"
                    || normalizedString == "1"
                    || normalizedString.contains("reasoning")
                    || normalizedString.contains("thinking")
                    || normalizedString.contains("enablethinking")
            }

            if let array = value as? [Any] {
                return !array.isEmpty
            }

            if let dictionary = value as? [String: Any] {
                return !dictionary.isEmpty
            }

            return false
        }

        private func normalizedToken(
            _ value: String
        ) -> String {
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
                .replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: " ", with: "")
        }
    }
}
