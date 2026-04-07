import Foundation
import SocketIO
import CodeLightCrypto
import CodeLightProtocol

/// Socket.io client for the CodeLight iPhone app.
/// Handles server connection, message receiving, and sending.
@MainActor
final class SocketClient {

    private let serverUrl: String
    private let keyManager: KeyManager
    private var token: String?
    private var manager: SocketManager?
    private var socket: SocketIOClient?

    var onSessionsUpdate: (([SessionInfo]) -> Void)?
    var onNewMessage: ((String, UpdateMessage) -> Void)?  // (sessionId, message)
    var onEphemeral: ((String, Bool) -> Void)?             // (sessionId, active)

    init(serverUrl: String, keyManager: KeyManager) {
        self.serverUrl = serverUrl
        self.keyManager = keyManager
        self.token = keyManager.loadToken(forServer: serverUrl)
    }

    // MARK: - Auth

    func authenticate() async throws {
        print("[SocketClient] Step 1: Creating key...")
        let _ = try keyManager.getOrCreateIdentityKey()
        print("[SocketClient] Step 2: Key ready")

        let challenge = UUID().uuidString
        let challengeData = Data(challenge.utf8)
        let signature = try keyManager.sign(challengeData)
        let publicKey = try keyManager.publicKeyBase64()
        print("[SocketClient] Step 3: Signed challenge, pubkey=\(publicKey.prefix(20))...")

        let request = AuthRequest(
            publicKey: publicKey,
            challenge: challengeData.base64EncodedString(),
            signature: signature.base64EncodedString()
        )

        let url = URL(string: "\(serverUrl)/v1/auth")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(request)
        urlRequest.timeoutInterval = 10

        print("[SocketClient] Step 4: Sending auth to \(url)...")
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let httpResponse = response as? HTTPURLResponse
        print("[SocketClient] Step 5: Got \(httpResponse?.statusCode ?? -1), body=\(String(data: data, encoding: .utf8)?.prefix(100) ?? "nil")")
        let authResponse = try JSONDecoder().decode(AuthResponse.self, from: data)

        if let t = authResponse.token {
            self.token = t
            try keyManager.storeToken(t, forServer: serverUrl)
        }
    }

    // MARK: - Connection

    func connect() {
        guard let token else { return }

        let url = URL(string: serverUrl)!
        manager = SocketManager(socketURL: url, config: [
            .log(false),
            .path("/v1/updates"),
            .connectParams(["token": token, "clientType": "user-scoped"]),
            .reconnects(true),
            .reconnectWait(1),
            .reconnectWaitMax(5),
            .forceWebsockets(true),
        ])

        socket = manager?.defaultSocket

        socket?.on("update") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any] else { return }
            Task { @MainActor in
                self?.handleUpdate(dict)
            }
        }

        socket?.on("ephemeral") { [weak self] data, _ in
            guard let dict = data.first as? [String: Any],
                  let sessionId = dict["sessionId"] as? String,
                  let active = dict["active"] as? Bool else { return }
            Task { @MainActor in
                self?.onEphemeral?(sessionId, active)
            }
        }

        socket?.connect()
    }

    func disconnect() {
        socket?.disconnect()
        manager = nil
        socket = nil
    }

    // MARK: - Sending

    func sendMessage(sessionId: String, content: String, localId: String? = nil) {
        var payload: [String: Any] = ["sid": sessionId, "message": content]
        if let localId { payload["localId"] = localId }
        socket?.emitWithAck("message", payload).timingOut(after: 30) { _ in }
    }

    func sendRpcCall(method: String, params: String) async -> [String: Any]? {
        guard let socket else { return nil }

        return await withCheckedContinuation { continuation in
            socket.emitWithAck("rpc-call", ["method": method, "params": params] as [String: Any])
                .timingOut(after: 300) { data in
                    let result = data.first as? [String: Any]
                    continuation.resume(returning: result)
                }
        }
    }

    // MARK: - HTTP API

    func fetchSessions() async throws -> [SessionInfo] {
        let result = try await getJSON(path: "/v1/sessions")
        guard let sessions = result["sessions"] as? [[String: Any]] else { return [] }

        return sessions.compactMap { dict -> SessionInfo? in
            guard let id = dict["id"] as? String,
                  let tag = dict["tag"] as? String,
                  let active = dict["active"] as? Bool else { return nil }

            let metadataString = dict["metadata"] as? String
            var metadata: SessionMetadata?
            if let str = metadataString, let data = str.data(using: .utf8) {
                metadata = try? JSONDecoder().decode(SessionMetadata.self, from: data)
            }

            let lastActive = (dict["lastActiveAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()

            // Owner device info — projected by the server from the Session→Device join.
            let ownerDeviceId = dict["ownerDeviceId"] as? String
            let ownerDeviceName = dict["ownerDeviceName"] as? String

            return SessionInfo(
                id: id,
                tag: tag,
                metadata: metadata,
                active: active,
                lastActiveAt: lastActive,
                ownerDeviceId: ownerDeviceId,
                ownerDeviceName: ownerDeviceName
            )
        }
    }

    // MARK: - Multi-device pairing API

    /// Register this iPhone with the server (idempotent). Call once after auth.
    func registerDevice(name: String, kind: String) async throws {
        _ = try await postJSON(path: "/v1/devices/me", body: ["name": name, "kind": kind])
    }

    /// Redeem a Mac's permanent shortCode → creates a DeviceLink.
    func redeemPairingCode(_ code: String) async throws -> LinkedDevice {
        let result = try await postJSON(path: "/v1/pairing/code/redeem", body: ["code": code])
        guard let macId = result["macDeviceId"] as? String,
              let name = result["name"] as? String else {
            throw NSError(domain: "CodeLight.Pair", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: result["error"] as? String ?? "Pairing failed"])
        }
        let kind = result["kind"] as? String ?? "mac"
        return LinkedDevice(deviceId: macId, name: name, kind: kind, createdAt: ISO8601DateFormatter().string(from: Date()))
    }

    /// List all devices linked to this iPhone.
    func fetchLinks() async throws -> [LinkedDevice] {
        let url = URL(string: "\(serverUrl)/v1/pairing/links")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONDecoder().decode([LinkedDevice].self, from: data)) ?? []
    }

    /// Unlink a paired Mac.
    func unlinkDevice(_ deviceId: String) async throws {
        let url = URL(string: "\(serverUrl)/v1/pairing/links/\(deviceId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "CodeLight.Unlink", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Unlink failed (\(http.statusCode))"])
        }
    }

    /// Fetch a paired Mac's launch presets.
    func fetchPresets(macDeviceId: String) async throws -> [LaunchPresetDTO] {
        let url = URL(string: "\(serverUrl)/v1/devices/\(macDeviceId)/presets")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONDecoder().decode([LaunchPresetDTO].self, from: data)) ?? []
    }

    /// Fetch a paired Mac's known project paths.
    func fetchProjects(macDeviceId: String, limit: Int = 30) async throws -> [KnownProjectDTO] {
        let url = URL(string: "\(serverUrl)/v1/devices/\(macDeviceId)/projects?limit=\(limit)")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONDecoder().decode([KnownProjectDTO].self, from: data)) ?? []
    }

    /// Remote-launch a session on a paired Mac.
    func launchSession(macDeviceId: String, presetId: String, projectPath: String) async throws {
        _ = try await postJSON(path: "/v1/sessions/launch", body: [
            "macDeviceId": macDeviceId,
            "presetId": presetId,
            "projectPath": projectPath,
        ])
    }

    private func postJSON(path: String, body: [String: Any]) async throws -> [String: Any] {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let body = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let msg = body["error"] as? String ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "CodeLight.HTTP", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    struct FetchResult {
        let messages: [ChatMessage]
        let hasMore: Bool
    }

    /// Fetch latest messages (initial load)
    func fetchMessages(sessionId: String, limit: Int = 50) async throws -> FetchResult {
        let result = try await getJSON(path: "/v1/sessions/\(sessionId)/messages?limit=\(limit)")
        return parseFetchResult(result)
    }

    /// Fetch older messages (scroll up)
    func fetchOlderMessages(sessionId: String, beforeSeq: Int, limit: Int = 50) async throws -> FetchResult {
        let result = try await getJSON(path: "/v1/sessions/\(sessionId)/messages?before_seq=\(beforeSeq)&limit=\(limit)")
        return parseFetchResult(result)
    }

    /// Fetch newer messages (delta sync — used as a fallback when socket events
    /// are missed or arrive out of order).
    func fetchNewerMessages(sessionId: String, afterSeq: Int, limit: Int = 100) async throws -> FetchResult {
        let result = try await getJSON(path: "/v1/sessions/\(sessionId)/messages?after_seq=\(afterSeq)&limit=\(limit)")
        return parseFetchResult(result)
    }

    private func parseFetchResult(_ result: [String: Any]) -> FetchResult {
        let hasMore = result["hasMore"] as? Bool ?? false
        guard let messages = result["messages"] as? [[String: Any]] else {
            return FetchResult(messages: [], hasMore: false)
        }

        let parsed = messages.compactMap { dict -> ChatMessage? in
            guard let id = dict["id"] as? String,
                  let seq = dict["seq"] as? Int,
                  let content = dict["content"] as? String else { return nil }
            return ChatMessage(id: id, seq: seq, content: content, localId: dict["localId"] as? String)
        }
        return FetchResult(messages: parsed, hasMore: hasMore)
    }

    // MARK: - Event Handling

    private func handleUpdate(_ dict: [String: Any]) {
        guard let type = dict["type"] as? String else { return }

        switch type {
        case "new-message":
            if let sessionId = dict["sessionId"] as? String,
               let msgDict = dict["message"] as? [String: Any],
               let msgData = try? JSONSerialization.data(withJSONObject: msgDict),
               let msg = try? JSONDecoder().decode(UpdateMessage.self, from: msgData) {
                onNewMessage?(sessionId, msg)
            }
        default:
            break
        }
    }

    // MARK: - HTTP Helpers

    private func getJSON(path: String) async throws -> [String: Any] {
        let url = URL(string: "\(serverUrl)\(path)")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Fetch the capability snapshot (slash commands, skills, MCP servers) uploaded
    /// by CodeIsland for this device. Used by the phone's command picker.
    func fetchCapabilities() async throws -> CapabilitySnapshot {
        let url = URL(string: "\(serverUrl)/v1/capabilities")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw NSError(domain: "CodeLight.Capabilities", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "CodeIsland hasn't uploaded capabilities yet. Start CodeIsland on your Mac."])
        }
        return try JSONDecoder().decode(CapabilitySnapshot.self, from: data)
    }

    // MARK: - Notification Preferences

    struct NotificationPrefs: Codable, Equatable {
        var notifyOnCompletion: Bool
        var notifyOnApproval: Bool
        var notifyOnError: Bool
    }

    func fetchNotificationPrefs() async throws -> NotificationPrefs {
        let url = URL(string: "\(serverUrl)/v1/notification-prefs")!
        var request = URLRequest(url: url)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(NotificationPrefs.self, from: data)
    }

    func updateNotificationPrefs(_ prefs: NotificationPrefs) async throws -> NotificationPrefs {
        let url = URL(string: "\(serverUrl)/v1/notification-prefs")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(prefs)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CodeLight.Prefs", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to update notification prefs"])
        }
        return try JSONDecoder().decode(NotificationPrefs.self, from: data)
    }

    /// Upload an image blob. Returns the blobId on success.
    func uploadBlob(data: Data, mime: String) async throws -> String {
        let url = URL(string: "\(serverUrl)/v1/blobs")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue(mime, forHTTPHeaderField: "X-Blob-Mime")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (respData, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "CodeLight.Upload", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "Blob upload failed"])
        }
        let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] ?? [:]
        guard let blobId = json["blobId"] as? String else {
            throw NSError(domain: "CodeLight.Upload", code: -2, userInfo: [NSLocalizedDescriptionKey: "Missing blobId in response"])
        }
        return blobId
    }
}

/// A chat message from the server.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let seq: Int
    let content: String
    let localId: String?
}

/// Server update message payload.
struct UpdateMessage: Codable {
    let id: String
    let seq: Int
    let content: String
    let localId: String?
}
