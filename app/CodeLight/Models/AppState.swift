import Combine
import Foundation
import UIKit
import CodeLightCrypto
import CodeLightProtocol

/// Global app state — manages backend connections, paired Macs, and sessions.
///
/// **Concept model (multi-server, multi-mac):**
/// - `linkedMacs` is the source of truth — a flat list where each Mac carries its own `serverUrl`.
/// - At any moment ONE active socket is connected to ONE server. Tapping a Mac on a
///   different server triggers a disconnect+reconnect (`switchServerIfNeeded`).
/// - `currentServerUrl` reflects where the socket is pointed right now.
/// - `lastUsedServerUrl` (persisted) is used to auto-connect on app launch.
/// - KeyManager stores per-server tokens, so credentials are preserved across switches.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var linkedMacs: [LinkedMac] = []
    @Published var currentServerUrl: String?
    @Published var sessions: [SessionInfo] = []
    @Published var isConnected = false
    /// Time of the last real message received per session (not heartbeats/phase updates)
    @Published var lastMessageTimeBySession: [String: Date] = [:]

    /// Images the user sent locally, keyed by the blobId. Used by MessageRow to render
    /// attached images the user just sent — server blobs are ephemeral and can't be
    /// re-downloaded after delivery, so we keep a copy here until the app is killed.
    @Published var sentImageCache: [String: Data] = [:]

    /// New message events — ChatView subscribes to this
    let newMessageSubject = PassthroughSubject<(sessionId: String, message: ChatMessage), Never>()

    /// UserDefaults-backed: the server URL used in the most recent successful connection.
    /// Drives auto-connect on launch and prefills the pairing form.
    var lastUsedServerUrl: String? {
        get { UserDefaults.standard.string(forKey: "lastUsedServerUrl") }
        set {
            if let v = newValue {
                UserDefaults.standard.set(v, forKey: "lastUsedServerUrl")
            } else {
                UserDefaults.standard.removeObject(forKey: "lastUsedServerUrl")
            }
        }
    }

    /// All unique server URLs across linked Macs, sorted alphabetically.
    var knownServerUrls: [String] {
        Array(Set(linkedMacs.map { $0.serverUrl })).sorted()
    }

    private let keyManager = KeyManager(serviceName: "com.codelight.app")
    private(set) var socket: SocketClient?

    private init() {
        loadLinkedMacs()
        migrateLegacyIfNeeded()
    }

    // MARK: - Server / Mac Management

    /// Wipe all paired Macs and disconnect. Used by the "Reset" button in Settings.
    func reset() {
        linkedMacs = []
        saveLinkedMacs()
        lastUsedServerUrl = nil
        disconnect()
    }

    /// Auto-connect to the most recently used server on app launch. If no recent
    /// server exists, do nothing (user must pair to set a server URL).
    func connect() async {
        if let url = lastUsedServerUrl ?? linkedMacs.first?.serverUrl {
            await connectToServer(url: url)
        }
    }

    /// Connect to a specific server URL if not already connected there. Used when
    /// the user taps a Mac on a different server.
    func switchServerIfNeeded(to url: String) async {
        if currentServerUrl == url && isConnected { return }
        await connectToServer(url: url)
    }

    func connectToServer(url: String) async {
        disconnect()

        let client = SocketClient(serverUrl: url, keyManager: keyManager)
        self.socket = client

        do {
            try await client.authenticate()

            // Register this iPhone with the server (sets kind=ios, name=device name)
            let deviceName = await iOSDeviceName()
            try? await client.registerDevice(name: deviceName, kind: "ios")

            client.connect()
            client.onSessionsUpdate = { [weak self] sessions in
                self?.sessions = sessions
            }
            client.onNewMessage = { [weak self] sessionId, msg in
                let chatMsg = ChatMessage(id: msg.id, seq: msg.seq, content: msg.content, localId: msg.localId)
                self?.newMessageSubject.send((sessionId: sessionId, message: chatMsg))

                if let data = msg.content.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let type = dict["type"] as? String,
                   type != "phase" {
                    self?.lastMessageTimeBySession[sessionId] = Date()
                }

                let serverName = URL(string: url)?.host ?? "Server"
                self?.updateLiveActivity(sessionId: sessionId, content: msg.content, serverName: serverName)
            }
            client.onEphemeral = { _, _ in }
            isConnected = true
            currentServerUrl = url
            lastUsedServerUrl = url
            print("[AppState] Connected to \(url)")

            // Upload the cached APNs device token now that the socket is up.
            // PushManager often gets the device token from iOS BEFORE we have a
            // server URL on launch, so it caches the token and waits for this.
            Task { await PushManager.shared.uploadStoredTokenIfNeeded() }

            // Refresh linked Macs and sessions in parallel
            async let linksTask: () = refreshLinkedMacs()
            do {
                let fetched = try await client.fetchSessions()
                self.sessions = fetched
            } catch {
                print("[AppState] Failed to fetch sessions: \(error)")
            }
            _ = await linksTask
        } catch {
            isConnected = false
            currentServerUrl = nil
            print("[AppState] Connection failed: \(error)")
        }
    }

    /// Merge fetched links from the current server into the local list.
    /// Doesn't clobber entries from other servers — only updates/adds rows
    /// whose `serverUrl` matches `currentServerUrl`.
    func refreshLinkedMacs() async {
        guard let socket, let currentUrl = currentServerUrl else { return }
        do {
            let links = try await socket.fetchLinks()
            let freshFromThisServer: [LinkedMac] = links
                .filter { $0.kind == "mac" }
                .map { LinkedMac(
                    deviceId: $0.deviceId,
                    name: $0.name,
                    kind: $0.kind,
                    createdAt: $0.createdAt,
                    serverUrl: currentUrl
                ) }

            // Drop any locally-cached rows from THIS server that no longer exist upstream,
            // keep rows from other servers untouched.
            let freshIds = Set(freshFromThisServer.map(\.deviceId))
            let otherServerRows = linkedMacs.filter { $0.serverUrl != currentUrl }
            let thisServerRowsStillValid = linkedMacs.filter {
                $0.serverUrl == currentUrl && freshIds.contains($0.deviceId)
            }
            // Add any new ones from the fetch that weren't in the local cache
            let existingIds = Set(thisServerRowsStillValid.map(\.deviceId))
            let newOnes = freshFromThisServer.filter { !existingIds.contains($0.deviceId) }

            linkedMacs = otherServerRows + thisServerRowsStillValid + newOnes
            saveLinkedMacs()
        } catch {
            print("[AppState] Failed to fetch links: \(error)")
        }
    }

    /// Pair with a Mac on a specific server. Switches backend first if needed.
    /// Returns the newly linked Mac.
    @discardableResult
    func pairWithCode(_ code: String, onServer serverUrl: String) async throws -> LinkedMac {
        // Switch to the target server first (authenticates + opens socket)
        if currentServerUrl != serverUrl || !isConnected {
            await connectToServer(url: serverUrl)
        }
        guard let socket, isConnected else {
            throw NSError(domain: "CodeLight.Pair", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not connect to \(serverUrl)"])
        }

        let device = try await socket.redeemPairingCode(code)
        let mac = LinkedMac(
            deviceId: device.deviceId,
            name: device.name,
            kind: device.kind,
            createdAt: device.createdAt,
            serverUrl: serverUrl
        )
        if !linkedMacs.contains(where: { $0.deviceId == mac.deviceId && $0.serverUrl == serverUrl }) {
            linkedMacs.append(mac)
            saveLinkedMacs()
        }
        // Refresh sessions so the new Mac's sessions appear immediately
        if let fetched = try? await socket.fetchSessions() {
            self.sessions = fetched
        }
        return mac
    }

    func unlinkMac(_ mac: LinkedMac) async {
        // Unlink must happen on the Mac's own server
        if currentServerUrl != mac.serverUrl {
            await connectToServer(url: mac.serverUrl)
        }
        guard let socket else { return }
        do {
            try await socket.unlinkDevice(mac.deviceId)
            linkedMacs.removeAll { $0.deviceId == mac.deviceId && $0.serverUrl == mac.serverUrl }
            sessions.removeAll { $0.ownerDeviceId == mac.deviceId }
            saveLinkedMacs()
        } catch {
            print("[AppState] Failed to unlink: \(error)")
        }
    }

    func disconnect() {
        socket?.disconnect()
        socket = nil
        sessions = []
        isConnected = false
        currentServerUrl = nil
    }

    private func iOSDeviceName() async -> String {
        await MainActor.run {
            #if canImport(UIKit)
            return UIDevice.current.name
            #else
            return "iPhone"
            #endif
        }
    }

    // MARK: - Messaging

    func sendMessage(_ text: String, toSession sessionId: String, localId: String? = nil) {
        guard let socket else { return }
        let id = localId ?? UUID().uuidString
        socket.sendMessage(sessionId: sessionId, content: text, localId: id)
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

    /// Start the GLOBAL Live Activity with the most recently active session's state
    func startLiveActivitiesForActiveSessions() {
        let serverName = currentServerUrl.flatMap { URL(string: $0)?.host } ?? "Server"
        guard let socket = self.socket else { return }

        let activeSessions = sessions.filter { $0.active }
        let totalCount = sessions.count
        let activeCount = activeSessions.count

        guard let session = activeSessions.first ?? sessions.first else {
            LiveActivityManager.shared.end()
            return
        }

        Task { [weak self] in
            let (phase, toolName, userMsg, assistantMsg) = await self?.fetchLatestPhaseState(sessionId: session.id, socket: socket) ?? ("idle", nil, nil, nil)

            await MainActor.run {
                LiveActivityManager.shared.updateGlobal(
                    activeSessionId: session.id,
                    projectName: session.metadata?.displayProjectName ?? "Session",
                    projectPath: session.metadata?.path,
                    phase: phase,
                    toolName: toolName,
                    lastUserMessage: userMsg,
                    lastAssistantSummary: assistantMsg,
                    totalSessions: totalCount,
                    activeSessions: activeCount,
                    serverName: serverName
                )
                if let u = userMsg { self?.lastUserMessageBySession[session.id] = u }
                if let a = assistantMsg { self?.lastAssistantMessageBySession[session.id] = a }
            }
        }
    }

    /// Fetch latest messages for a session and extract the most recent phase state.
    private func fetchLatestPhaseState(sessionId: String, socket: SocketClient) async -> (phase: String, toolName: String?, userMsg: String?, assistantMsg: String?) {
        do {
            let result = try await socket.fetchMessages(sessionId: sessionId)
            var phase = "idle"
            var toolName: String? = nil
            var userMsg: String? = nil
            var assistantMsg: String? = nil

            // Iterate most recent first
            for msg in result.messages.reversed() {
                guard let data = msg.content.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = dict["type"] as? String else { continue }

                // Latest phase message wins
                if type == "phase", phase == "idle", toolName == nil {
                    phase = dict["phase"] as? String ?? "idle"
                    toolName = dict["toolName"] as? String
                }
                // Latest user message
                if userMsg == nil, type == "user", let text = dict["text"] as? String {
                    userMsg = String(text.prefix(120))
                }
                // Latest assistant message
                if assistantMsg == nil, type == "assistant", let text = dict["text"] as? String, !text.isEmpty {
                    assistantMsg = String(text.prefix(200))
                }

                if userMsg != nil && assistantMsg != nil && phase != "idle" { break }
            }

            return (phase, toolName, userMsg, assistantMsg)
        } catch {
            return ("idle", nil, nil, nil)
        }
    }


    /// Track last user/assistant message per session for Dynamic Island display
    private var lastUserMessageBySession: [String: String] = [:]
    private var lastAssistantMessageBySession: [String: String] = [:]

    private func updateLiveActivity(sessionId: String, content: String, serverName: String) {
        guard let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = dict["type"] as? String else { return }

        let sessionMeta = sessions.first(where: { $0.id == sessionId })?.metadata
        let projectName = sessionMeta?.displayProjectName ?? "Session"
        let projectPath = sessionMeta?.path

        // Track user/assistant messages
        if type == "user", let text = dict["text"] as? String {
            lastUserMessageBySession[sessionId] = String(text.prefix(120))
        } else if type == "assistant", let text = dict["text"] as? String, !text.isEmpty {
            lastAssistantMessageBySession[sessionId] = String(text.prefix(200))
        }

        // Only phase messages update the GLOBAL Live Activity (they're the event signal)
        guard type == "phase" else { return }

        let phase = dict["phase"] as? String ?? "idle"
        let toolName = dict["toolName"] as? String
        if let userMsg = dict["lastUserMessage"] as? String {
            lastUserMessageBySession[sessionId] = userMsg
        }
        if let assistantMsg = dict["lastAssistantSummary"] as? String {
            lastAssistantMessageBySession[sessionId] = assistantMsg
        }

        let totalCount = sessions.count
        let activeCount = sessions.filter { $0.active }.count

        // Update the global Live Activity to show THIS session (whichever had the latest event)
        LiveActivityManager.shared.updateGlobal(
            activeSessionId: sessionId,
            projectName: projectName,
            projectPath: projectPath,
            phase: phase,
            toolName: toolName,
            lastUserMessage: lastUserMessageBySession[sessionId],
            lastAssistantSummary: lastAssistantMessageBySession[sessionId],
            totalSessions: totalCount,
            activeSessions: activeCount,
            serverName: serverName
        )
    }


    // MARK: - Persistence

    private func loadLinkedMacs() {
        if let data = UserDefaults.standard.data(forKey: "linkedMacs.v2"),
           let macs = try? JSONDecoder().decode([LinkedMac].self, from: data) {
            linkedMacs = macs
        }
    }

    private func saveLinkedMacs() {
        guard let data = try? JSONEncoder().encode(linkedMacs) else { return }
        UserDefaults.standard.set(data, forKey: "linkedMacs.v2")
    }

    /// One-shot migration: clear any stale pre-multi-server UserDefaults keys.
    /// Old builds stored a single `backend` singleton or a `servers` array, and
    /// old `linkedMacs` (v1) lacked the `serverUrl` field — all unusable in the
    /// new flat-list-with-serverUrl model. We drop them and let the user re-pair.
    private func migrateLegacyIfNeeded() {
        let legacyKeys = ["backend", "servers", "linkedMacs"]
        var didRemove = false
        for key in legacyKeys where UserDefaults.standard.object(forKey: key) != nil {
            // Try to salvage a server URL hint for lastUsedServerUrl before dropping
            if key == "backend", let data = UserDefaults.standard.data(forKey: key),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = dict["url"] as? String, lastUsedServerUrl == nil {
                lastUsedServerUrl = url
            }
            if key == "servers", let data = UserDefaults.standard.data(forKey: key),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               let first = arr.first, let url = first["url"] as? String, lastUsedServerUrl == nil {
                lastUsedServerUrl = url
            }
            UserDefaults.standard.removeObject(forKey: key)
            didRemove = true
        }
        if didRemove {
            print("[AppState] Cleared legacy state keys; lastUsedServerUrl=\(lastUsedServerUrl ?? "nil")")
        }
    }
}

/// A Mac that has been paired with this iPhone via DeviceLink.
/// Each row carries its own `serverUrl` — multi-server is supported by having
/// Macs from different servers coexist in the same list.
struct LinkedMac: Codable, Identifiable, Hashable {
    let deviceId: String
    var name: String
    let kind: String      // always "mac" in the UI
    let createdAt: String // ISO8601
    let serverUrl: String // which server this Mac lives on

    /// Composite id — (deviceId, serverUrl) — avoids collisions if two different
    /// servers happen to issue the same cuid (very unlikely but cheap to guard against).
    var id: String { "\(serverUrl)#\(deviceId)" }

    var serverHost: String {
        URL(string: serverUrl)?.host ?? serverUrl
    }
}

/// Session info from server.
struct SessionInfo: Identifiable {
    let id: String
    let tag: String
    let metadata: SessionMetadata?
    let active: Bool
    let lastActiveAt: Date
    /// Owner Mac's server-side deviceId. Used to filter sessions per-Mac in the UI.
    let ownerDeviceId: String?
    /// Owner Mac's display name (from the server-side join).
    let ownerDeviceName: String?
}
