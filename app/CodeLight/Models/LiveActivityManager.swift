import ActivityKit
import CodeLightCrypto
import Foundation
import os.log

/// Manages the GLOBAL CodeLight Live Activity (one per device, not per session).
/// The activity shows the currently-most-active session's state and aggregate counts.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private static let logger = Logger(subsystem: "com.codelight.app", category: "LiveActivity")

    /// The single global activity (if started)
    private var activity: Activity<CodeLightActivityAttributes>?

    private init() {}

    /// Start or update the global Live Activity with the current focus session + counts.
    func updateGlobal(
        activeSessionId: String,
        projectName: String,
        projectPath: String?,
        phase: String,
        toolName: String?,
        lastUserMessage: String?,
        lastAssistantSummary: String?,
        totalSessions: Int,
        activeSessions: Int,
        serverName: String
    ) {
        let state = CodeLightActivityAttributes.ContentState(
            activeSessionId: activeSessionId,
            projectName: projectName,
            projectPath: projectPath,
            phase: phase,
            toolName: toolName,
            lastUserMessage: lastUserMessage,
            lastAssistantSummary: lastAssistantSummary,
            totalSessions: totalSessions,
            activeSessions: activeSessions,
            startedAt: activity?.content.state.startedAt ?? Date().timeIntervalSince1970
        )

        if let existing = activity {
            Task {
                await existing.update(ActivityContent(state: state, staleDate: nil))
            }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                print("[LiveActivity] Not enabled in iOS Settings")
                return
            }

            let attributes = CodeLightActivityAttributes(serverName: serverName)

            do {
                let newActivity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: .token
                )
                activity = newActivity
                print("[LiveActivity] STARTED global activity")

                // Register push token
                Task { [weak self] in
                    for await tokenData in newActivity.pushTokenUpdates {
                        let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
                        print("[LiveActivity] Push token: \(tokenString.prefix(16))...")
                        await self?.registerToken(token: tokenString)
                    }
                }
            } catch {
                print("[LiveActivity] FAILED: \(error)")
            }
        }
    }

    /// End the global Live Activity.
    func end() {
        guard let existing = activity else { return }
        Task {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
    }

    /// Register the global Live Activity push token with the server.
    /// Uses a special sessionId "__global__" to identify this as the global activity.
    private func registerToken(token: String) async {
        guard let serverUrl = AppState.shared.currentServerUrl,
              let authToken = KeyManager(serviceName: "com.codelight.app").loadToken(forServer: serverUrl) else {
            return
        }

        let url = URL(string: "\(serverUrl)/v1/live-activity-tokens")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "sessionId": "__global__",
            "token": token,
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                print("[LiveActivity] Global token registered")
            }
        } catch {
            print("[LiveActivity] Failed to register: \(error)")
        }
    }
}
