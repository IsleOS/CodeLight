import Foundation

struct ParsedChatContent: Equatable {
    let type: String
    let text: String
    let toolName: String?
    let toolStatus: String?
    let imageBlobIds: [String]
    let command: String?
    let phase: String?

    static func plainUserText(_ text: String) -> ParsedChatContent {
        ParsedChatContent(
            type: "user",
            text: text,
            toolName: nil,
            toolStatus: nil,
            imageBlobIds: [],
            command: nil,
            phase: nil
        )
    }
}

enum ChatContentParser {
    static func parse(_ content: String) -> ParsedChatContent {
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return .plainUserText(content)
        }

        return parse(dict, fallbackText: content)
    }

    private static func parse(_ dict: [String: Any], fallbackText: String) -> ParsedChatContent {
        guard let type = dict["type"] as? String else {
            return .plainUserText(fallbackText)
        }

        switch type {
        case "user", "assistant", "thinking", "tool", "interrupted", "terminal_output", "phase", "heartbeat", "key", "config", "read-screen":
            return parseNormalizedEnvelope(dict, type: type)
        case "response_item":
            return parseResponseItem(dict["payload"] as? [String: Any], fallbackText: fallbackText)
        case "event_msg":
            return parseEventMessage(dict["payload"] as? [String: Any], fallbackText: fallbackText)
        default:
            return ParsedChatContent(
                type: type,
                text: dict["text"] as? String ?? fallbackText,
                toolName: dict["toolName"] as? String,
                toolStatus: dict["toolStatus"] as? String,
                imageBlobIds: extractBlobIds(dict),
                command: dict["command"] as? String,
                phase: dict["phase"] as? String
            )
        }
    }

    private static func parseNormalizedEnvelope(_ dict: [String: Any], type: String) -> ParsedChatContent {
        ParsedChatContent(
            type: type,
            text: dict["text"] as? String ?? "",
            toolName: dict["toolName"] as? String,
            toolStatus: dict["toolStatus"] as? String,
            imageBlobIds: extractBlobIds(dict),
            command: dict["command"] as? String,
            phase: dict["phase"] as? String
        )
    }

    private static func parseResponseItem(_ payload: [String: Any]?, fallbackText: String) -> ParsedChatContent {
        guard let payload, let payloadType = payload["type"] as? String else {
            return .plainUserText(fallbackText)
        }

        switch payloadType {
        case "message":
            let role = (payload["role"] as? String) == "user" ? "user" : "assistant"
            let text = messageText(from: payload["content"] as? [[String: Any]], role: role)
            return ParsedChatContent(
                type: role,
                text: text,
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: payload["phase"] as? String
            )

        case "custom_tool_call", "function_call":
            let toolName = payload["name"] as? String ?? payloadType
            let toolText = stringValue(payload["input"]) ?? ""
            return ParsedChatContent(
                type: "tool",
                text: toolText,
                toolName: toolName,
                toolStatus: payload["status"] as? String ?? "running",
                imageBlobIds: [],
                command: nil,
                phase: nil
            )

        case "custom_tool_call_output", "function_call_output":
            let output = payload["output"] as? String ?? ""
            return ParsedChatContent(
                type: "terminal_output",
                text: output,
                toolName: nil,
                toolStatus: payload["status"] as? String,
                imageBlobIds: [],
                command: nil,
                phase: nil
            )

        case "reasoning":
            let text = payload["text"] as? String
                ?? stringValue(payload["summary"])
                ?? ""
            return ParsedChatContent(
                type: "thinking",
                text: text,
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: nil
            )

        default:
            return ParsedChatContent(
                type: payloadType,
                text: payload["text"] as? String ?? stringValue(payload["output"]) ?? fallbackText,
                toolName: payload["name"] as? String,
                toolStatus: payload["status"] as? String,
                imageBlobIds: [],
                command: nil,
                phase: payload["phase"] as? String
            )
        }
    }

    private static func parseEventMessage(_ payload: [String: Any]?, fallbackText: String) -> ParsedChatContent {
        guard let payload, let payloadType = payload["type"] as? String else {
            return .plainUserText(fallbackText)
        }

        switch payloadType {
        case "user_message":
            return ParsedChatContent(
                type: "user",
                text: payload["message"] as? String ?? "",
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: payload["phase"] as? String
            )

        case "agent_message":
            return ParsedChatContent(
                type: "assistant",
                text: payload["message"] as? String ?? "",
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: payload["phase"] as? String
            )

        case "exec_command_begin":
            let command = joinedCommand(payload["command"]) ?? ""
            return ParsedChatContent(
                type: "tool",
                text: command,
                toolName: "exec_command",
                toolStatus: "running",
                imageBlobIds: [],
                command: command.isEmpty ? nil : command,
                phase: nil
            )

        case "exec_command_end":
            let aggregated = payload["aggregated_output"] as? String
            let stdout = payload["stdout"] as? String
            let stderr = payload["stderr"] as? String
            let text = firstNonEmpty(aggregated, stdout, stderr) ?? ""
            return ParsedChatContent(
                type: "terminal_output",
                text: text,
                toolName: "exec_command",
                toolStatus: payload["status"] as? String ?? "completed",
                imageBlobIds: [],
                command: joinedCommand(payload["command"]),
                phase: nil
            )

        case "token_count":
            return ParsedChatContent(
                type: "heartbeat",
                text: "",
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: nil
            )

        case "turn_aborted":
            return ParsedChatContent(
                type: "interrupted",
                text: payload["reason"] as? String ?? "",
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: nil
            )

        default:
            let message = payload["message"] as? String
                ?? payload["output"] as? String
                ?? fallbackText
            return ParsedChatContent(
                type: "assistant",
                text: message,
                toolName: nil,
                toolStatus: nil,
                imageBlobIds: [],
                command: nil,
                phase: payload["phase"] as? String
            )
        }
    }

    private static func extractBlobIds(_ dict: [String: Any]) -> [String] {
        guard let images = dict["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { $0["blobId"] as? String }
    }

    private static func messageText(from content: [[String: Any]]?, role: String) -> String {
        guard let content else { return "" }
        let preferredTypes = role == "user"
            ? Set(["input_text", "text"])
            : Set(["output_text", "text"])

        let preferred = content.compactMap { item -> String? in
            guard let type = item["type"] as? String,
                  preferredTypes.contains(type),
                  let text = item["text"] as? String else {
                return nil
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !preferred.isEmpty {
            return preferred.joined(separator: "\n")
        }

        let fallback = content.compactMap { item -> String? in
            if let text = item["text"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }
        return fallback.joined(separator: "\n")
    }

    private static func joinedCommand(_ value: Any?) -> String? {
        if let command = value as? [String], !command.isEmpty {
            return command.joined(separator: " ")
        }
        if let command = value as? String, !command.isEmpty {
            return command
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return string
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.isEmpty
        } ?? nil
    }
}
