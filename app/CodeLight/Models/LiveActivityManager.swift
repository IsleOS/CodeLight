import ActivityKit
import CodeLightCrypto
import Foundation
import os.log

/// Manages Live Activities for active Claude Code sessions.
@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private static let logger = Logger(subsystem: "com.codelight.app", category: "LiveActivity")

    /// Active Live Activities keyed by sessionId.
    private var activities: [String: Activity<CodeLightActivityAttributes>] = [:]

    private init() {}

    /// Start or update a Live Activity for a session.
    func update(
        sessionId: String,
        phase: String?,
        toolName: String?,
        projectName: String,
        serverName: String,
        lastUserMessage: String? = nil,
        lastAssistantSummary: String? = nil
    ) {
        if let existing = activities[sessionId] {
            let prevState = existing.content.state
            // If phase not provided, preserve existing phase
            let finalPhase = phase ?? prevState.phase
            let finalTool = phase == nil ? prevState.toolName : toolName
            let newUserMsg = lastUserMessage ?? prevState.lastUserMessage
            let newAssistantSummary = lastAssistantSummary ?? prevState.lastAssistantSummary

            let state = CodeLightActivityAttributes.ContentState(
                phase: finalPhase,
                toolName: finalTool,
                projectName: projectName,
                lastUserMessage: newUserMsg,
                lastAssistantSummary: newAssistantSummary,
                startedAt: existing.content.state.startedAt
            )
            Task {
                await existing.update(ActivityContent(state: state, staleDate: nil))
            }
        } else if let phaseUnwrapped = phase {
            // Only create new activity if phase is provided
            let authInfo = ActivityAuthorizationInfo()
            guard authInfo.areActivitiesEnabled else {
                print("[LiveActivity] BLOCKED: Live Activities not enabled in iOS Settings")
                return
            }

            let attributes = CodeLightActivityAttributes(sessionId: sessionId, serverName: serverName)
            let state = CodeLightActivityAttributes.ContentState(
                phase: phaseUnwrapped,
                toolName: toolName,
                projectName: projectName,
                lastUserMessage: lastUserMessage,
                lastAssistantSummary: lastAssistantSummary,
                startedAt: Date()
            )

            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: .token  // Use APNs push for updates
                )
                activities[sessionId] = activity
                print("[LiveActivity] STARTED activity for \(sessionId.prefix(8))")

                // Observe push token updates
                Task { [weak self] in
                    for await tokenData in activity.pushTokenUpdates {
                        let tokenString = tokenData.map { String(format: "%02x", $0) }.joined()
                        print("[LiveActivity] Push token for \(sessionId.prefix(8)): \(tokenString.prefix(16))...")
                        await self?.registerLiveActivityToken(sessionId: sessionId, token: tokenString)
                    }
                }
            } catch {
                print("[LiveActivity] FAILED to start: \(error)")
            }
        }
    }

    /// Register Live Activity push token with server
    private func registerLiveActivityToken(sessionId: String, token: String) async {
        guard let serverUrl = AppState.shared.currentServer?.url,
              let authToken = KeyManager(serviceName: "com.codelight.app").loadToken(forServer: serverUrl) else {
            return
        }

        let url = URL(string: "\(serverUrl)/v1/live-activity-tokens")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "token": token,
        ])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                print("[LiveActivity] Token registered with server")
            }
        } catch {
            print("[LiveActivity] Failed to register token: \(error)")
        }
    }

    /// End the Live Activity for a session.
    func end(sessionId: String) {
        guard let activity = activities.removeValue(forKey: sessionId) else { return }

        let finalState = CodeLightActivityAttributes.ContentState(
            phase: "ended",
            toolName: nil,
            projectName: activity.content.state.projectName,
            startedAt: Date()
        )

        Task {
            await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .after(.now + 5))
            Self.logger.info("Ended activity for \(sessionId)")
        }
    }

    /// End all active Live Activities.
    func endAll() {
        for (sessionId, _) in activities {
            end(sessionId: sessionId)
        }
    }
}
