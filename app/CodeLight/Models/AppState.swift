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
            }
            isConnected = true
            print("[AppState] Connected to \(server.url)")
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
