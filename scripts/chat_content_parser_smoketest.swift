import Foundation

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
    return true
}

@main
struct ChatContentParserSmokeTest {
    static func main() {
        let responseItem = """
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Assistant reply"}]}}
        """
        let parsedResponse = ChatContentParser.parse(responseItem)
        expect(parsedResponse.type == "assistant", "response_item assistant should normalize to assistant")
        expect(parsedResponse.text == "Assistant reply", "response_item assistant text should be extracted")

        let eventMessage = """
        {"type":"event_msg","payload":{"type":"agent_message","message":"Progress update","phase":"commentary"}}
        """
        let parsedEvent = ChatContentParser.parse(eventMessage)
        expect(parsedEvent.type == "assistant", "event_msg agent_message should normalize to assistant")
        expect(parsedEvent.text == "Progress update", "event_msg message text should be extracted")

        let execOutput = """
        {"type":"event_msg","payload":{"type":"exec_command_end","command":["/bin/zsh","-lc","pwd"],"aggregated_output":"/Users/ying/Documents/AI\\n","status":"completed"}}
        """
        let parsedExec = ChatContentParser.parse(execOutput)
        expect(parsedExec.type == "terminal_output", "exec_command_end should normalize to terminal_output")
        expect(parsedExec.command == "/bin/zsh -lc pwd", "exec_command_end command should be joined")
        expect(parsedExec.text.contains("/Users/ying/Documents/AI"), "exec_command_end output should be preserved")

        let toolCall = """
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","status":"completed","input":"*** Begin Patch"}}
        """
        let parsedTool = ChatContentParser.parse(toolCall)
        expect(parsedTool.type == "tool", "custom_tool_call should normalize to tool")
        expect(parsedTool.toolName == "apply_patch", "custom_tool_call should preserve tool name")

        print("ok")
    }
}
