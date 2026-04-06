import Combine
import Foundation
import CodeLightCrypto
import CodeLightProtocol

/// Global app state — manages server connections and sessions.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var servers: [ServerConfig] = []
    @Published var currentServer: ServerConfig?
    @Published var sessions: [SessionInfo] = []
    @Published var isConnected = false

    /// New message events — ChatView subscribes to this
    let newMessageSubject = PassthroughSubject<(sessionId: String, message: ChatMessage), Never>()

    private let keyManager = KeyManager(serviceName: "com.codelight.app")
    private(set) var socket: SocketClient?

    private init() {
        loadServers()
    }

    // MARK: - Server Management

    func addServer(_ config: ServerConfig) {
        servers.append(config)
        saveServers()
    }

    func removeServer(_ config: ServerConfig) {
        servers.removeAll { $0.id == config.id }
        if currentServer?.id == config.id {
            currentServer = nil
            disconnect()
        }
        saveServers()
    }

    func connectTo(_ server: ServerConfig) async {
        disconnect()
        currentServer = server

        let client = SocketClient(serverUrl: server.url, keyManager: keyManager)
        self.socket = client

        do {
            try await client.authenticate()
            client.connect()
            client.onSessionsUpdate = { [weak self] sessions in
                self?.sessions = sessions
            }
            client.onNewMessage = { [weak self] sessionId, msg in
                let chatMsg = ChatMessage(id: msg.id, seq: msg.seq, content: msg.content, localId: msg.localId)
                self?.newMessageSubject.send((sessionId: sessionId, message: chatMsg))

                // Trigger Dynamic Island based on message type
                self?.updateLiveActivity(sessionId: sessionId, content: msg.content, serverName: server.name)
            }
            client.onEphemeral = { [weak self] sessionId, active in
                if !active {
                    LiveActivityManager.shared.end(sessionId: sessionId)
                }
            }
            isConnected = true
            print("[AppState] Connected to \(server.url)")

            // Auto-fetch sessions and start Live Activities for active ones
            do {
                let fetched = try await client.fetchSessions()
                self.sessions = fetched
                startLiveActivitiesForActiveSessions()
            } catch {
                print("[AppState] Failed to fetch sessions: \(error)")
            }
        } catch {
            isConnected = false
            print("[AppState] Connection failed: \(error)")
        }
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        sessions = []
        isConnected = false
    }

    // MARK: - Messaging

    func sendMessage(_ text: String, toSession sessionId: String) {
        guard let socket else { return }
        let localId = UUID().uuidString
        socket.sendMessage(sessionId: sessionId, content: text, localId: localId)
    }

    /// Send a model/mode change via session metadata update
    func updateModelMode(sessionId: String, model: String, mode: String) {
        guard let socket else { return }
        let metadata: [String: Any] = ["model": model, "mode": mode]
        if let data = try? JSONSerialization.data(withJSONObject: metadata),
           let str = String(data: data, encoding: .utf8) {
            socket.sendMessage(sessionId: sessionId, content: "{\"type\":\"config\",\"model\":\"\(model)\",\"mode\":\"\(mode)\"}", localId: "config-\(UUID().uuidString)")
        }
    }

    // MARK: - Dynamic Island

    /// Start Live Activities for all active sessions
    func startLiveActivitiesForActiveSessions() {
        let serverName = currentServer?.name ?? "Server"
        for session in sessions where session.active {
            LiveActivityManager.shared.update(
                sessionId: session.id,
                phase: "idle",
                toolName: nil,
                projectName: session.metadata?.title ?? "Session",
                serverName: serverName
            )
        }
    }

    private var idleTimers: [String: Timer] = [:]

    private func updateLiveActivity(sessionId: String, content: String, serverName: String) {
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else { return }

        let projectName = sessions.first(where: { $0.id == sessionId })?.metadata?.title ?? "Session"

        // Cancel any pending idle timer for this session
        idleTimers[sessionId]?.invalidate()
        idleTimers[sessionId] = nil

        switch type {
        case "thinking":
            LiveActivityManager.shared.update(sessionId: sessionId, phase: "thinking", toolName: nil, projectName: projectName, serverName: serverName)
        case "tool":
            let toolName = dict["toolName"] as? String
            let toolStatus = dict["toolStatus"] as? String
            // Show "running" until status changes; use done state briefly for completed
            if toolStatus == "success" || toolStatus == "completed" {
                LiveActivityManager.shared.update(sessionId: sessionId, phase: "ended", toolName: toolName, projectName: projectName, serverName: serverName)
                scheduleIdle(sessionId: sessionId, projectName: projectName, serverName: serverName, after: 5)
            } else if toolStatus == "error" || toolStatus == "failed" {
                LiveActivityManager.shared.update(sessionId: sessionId, phase: "error", toolName: toolName, projectName: projectName, serverName: serverName)
                scheduleIdle(sessionId: sessionId, projectName: projectName, serverName: serverName, after: 8)
            } else {
                LiveActivityManager.shared.update(sessionId: sessionId, phase: "tool_running", toolName: toolName, projectName: projectName, serverName: serverName)
            }
        case "assistant":
            // Don't immediately go idle — give user a moment to see the activity
            // If no new event comes in 10s, fade to idle
            scheduleIdle(sessionId: sessionId, projectName: projectName, serverName: serverName, after: 10)
        case "user":
            // User just sent a message, expect Claude to start thinking
            LiveActivityManager.shared.update(sessionId: sessionId, phase: "thinking", toolName: nil, projectName: projectName, serverName: serverName)
        case "interrupted":
            LiveActivityManager.shared.update(sessionId: sessionId, phase: "error", toolName: "Interrupted", projectName: projectName, serverName: serverName)
            scheduleIdle(sessionId: sessionId, projectName: projectName, serverName: serverName, after: 5)
        default:
            break
        }
    }

    private func scheduleIdle(sessionId: String, projectName: String, serverName: String, after seconds: Double) {
        idleTimers[sessionId]?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in
                LiveActivityManager.shared.update(
                    sessionId: sessionId,
                    phase: "idle",
                    toolName: nil,
                    projectName: projectName,
                    serverName: serverName
                )
                self?.idleTimers[sessionId] = nil
            }
        }
        idleTimers[sessionId] = timer
    }

    // MARK: - Persistence

    private func loadServers() {
        guard let data = UserDefaults.standard.data(forKey: "servers"),
              let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return }
        servers = saved
    }

    private func saveServers() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: "servers")
    }
}

/// Server configuration — persisted.
struct ServerConfig: Codable, Identifiable, Hashable {
    let id: String
    let url: String
    let name: String
    let pairedAt: Date

    init(url: String, name: String) {
        self.id = UUID().uuidString
        self.url = url
        self.name = name
        self.pairedAt = Date()
    }
}

/// Session info from server.
struct SessionInfo: Identifiable {
    let id: String
    let tag: String
    let metadata: SessionMetadata?
    let active: Bool
    let lastActiveAt: Date
}
