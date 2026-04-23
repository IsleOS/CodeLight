import Testing
import Foundation
@testable import CodeLightProtocol

@Test func testSessionEnvelopeCodable() throws {
    let envelope = SessionEnvelope(type: .userMessage, content: "encrypted-content", localId: "local-1")
    let data = try JSONEncoder().encode(envelope)
    let decoded = try JSONDecoder().decode(SessionEnvelope.self, from: data)
    #expect(decoded.type == .userMessage)
    #expect(decoded.content == "encrypted-content")
    #expect(decoded.localId == "local-1")
}

@Test func testPairingQRPayload() throws {
    let qr = PairingQRPayload(serverUrl: "https://code.7ove.online", tempPublicKey: "abc123", deviceName: "Mac")
    let data = try JSONEncoder().encode(qr)
    let decoded = try JSONDecoder().decode(PairingQRPayload.self, from: data)
    #expect(decoded.serverUrl == "https://code.7ove.online")
    #expect(decoded.tempPublicKey == "abc123")
    #expect(decoded.deviceName == "Mac")
}

@Test func testSessionPhaseValues() {
    #expect(SessionPhase.thinking.rawValue == "thinking")
    #expect(SessionPhase.toolRunning.rawValue == "tool_running")
    #expect(SessionPhase.waitingApproval.rawValue == "waiting_approval")
}
