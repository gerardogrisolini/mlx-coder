import Foundation
@testable import MLXCoderCore
import Testing

@Suite
struct ACPCompatibilityTests {
    @Test
    func toolCallUpdatesUseACPv1WireKeys() throws {
        let toolCall = DirectAgentToolCall(
            id: "call_001",
            name: "local.exec",
            argumentsObject: [
                "command": "swift test",
                "workingDirectory": "/tmp/workspace"
            ],
            argumentsJSON: #"{"command":"swift test","workingDirectory":"/tmp/workspace"}"#
        )

        let create = MLXCoderACPBridge.toolCallCreateUpdate(for: toolCall)
        #expect(create["sessionUpdate"] as? String == "tool_call")
        #expect(create["toolCallId"] as? String == "call_001")
        #expect(create["kind"] as? String == "execute")
        #expect(create["status"] as? String == "pending")
        #expect(create["tool_call_id"] == nil)

        let progress = MLXCoderACPBridge.toolCallProgressUpdate(for: toolCall)
        #expect(progress["sessionUpdate"] as? String == "tool_call_update")
        #expect(progress["toolCallId"] as? String == "call_001")
        #expect(progress["status"] as? String == "in_progress")

        let completion = MLXCoderACPBridge.toolCallCompletionUpdate(
            for: toolCall,
            result: DirectAgentToolResult(
                output: "Build complete.",
                summary: "Build complete."
            )
        )
        #expect(completion["sessionUpdate"] as? String == "tool_call_update")
        #expect(completion["toolCallId"] as? String == "call_001")
        #expect(completion["status"] as? String == "completed")
    }

    @Test
    func permissionResponsesAcceptACPAndAionUIShapes() {
        let cases: [(JSONValue, String)] = [
            (.string("allow_once"), "allow_once"),
            (.object(["optionId": .string("allow_always")]), "allow_always"),
            (.object(["optionID": .string("allow_upper")]), "allow_upper"),
            (.object(["option_id": .string("allow_snake")]), "allow_snake"),
            (.object(["confirmKey": .string("allow_confirm")]), "allow_confirm"),
            (.object(["confirm_key": .string("allow_confirm_snake")]), "allow_confirm_snake"),
            (.object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string("reject_once")
                ])
            ]), "reject_once"),
            (.object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "option_id": .string("reject_always")
                ])
            ]), "reject_always"),
            (.object([
                "selected": .object([
                    "confirm_key": .string("allow_selected")
                ])
            ]), "allow_selected")
        ]

        for (value, expected) in cases {
            #expect(ACPPermissionBroker.permissionOptionID(from: value) == expected)
        }
    }

    @Test
    func cancelledPermissionOutcomeDoesNotSelectOption() {
        let value = JSONValue.object([
            "outcome": .object([
                "outcome": .string("cancelled")
            ])
        ])

        #expect(ACPPermissionBroker.permissionOptionID(from: value) == nil)
    }

    @Test
    func sessionUpdatesWrapPayloadInStandardNotificationShape() {
        let notification = JSONValue.acpValue(from: [
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": [
                "sessionId": "session-1",
                "update": MLXCoderACPBridge.contextWindowUpdate(
                    for: DirectAgentContextWindowStatus(
                        usedTokens: 42,
                        maxTokens: 4096,
                        modelID: "local-model",
                        isApproximate: true
                    )
                )
            ]
        ])

        let object = notification.mlxObjectValue
        #expect(object?["method"]?.acpStringValue == "session/update")
        let params = object?["params"]?.mlxObjectValue
        #expect(params?["sessionId"]?.acpStringValue == "session-1")
        let update = params?["update"]?.mlxObjectValue
        #expect(update?["sessionUpdate"]?.acpStringValue == "context_window_update")
        #expect(update?["modelID"]?.acpStringValue == "local-model")
    }
}
