import CodeLightCrypto
import Foundation
import UIKit
import UserNotifications
import os.log

/// Manages push notification registration and token handling.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()
    private static let logger = Logger(subsystem: "com.codelight.app", category: "Push")

    @Published var isRegistered = false
    private var deviceToken: String?

    override private init() {
        super.init()
    }

    /// Request notification permissions and register for remote notifications.
    /// Called every app launch. Also re-registers if permission was already
    /// granted on a previous launch — iOS will then fire the device token
    /// callback so we can re-upload the current (possibly rotated) token.
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined:
                let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                    Self.logger.info("Push permission granted; registering")
                } else {
                    Self.logger.info("Push permission denied")
                }
            case .authorized, .provisional, .ephemeral:
                // Already authorized on a previous launch — kick the registration
                // again so iOS calls back with the current device token, which
                // lets us re-upload it to the server in case the install changed
                // or the server forgot about it.
                UIApplication.shared.registerForRemoteNotifications()
                Self.logger.info("Push already authorized; re-registering")
            case .denied:
                Self.logger.info("Push denied by user — cannot register")
            @unknown default:
                UIApplication.shared.registerForRemoteNotifications()
            }
        } catch {
            Self.logger.error("Push permission error: \(error)")
        }
    }

    /// Called by AppDelegate when device token is received.
    func didRegisterForRemoteNotifications(deviceToken data: Data) {
        let token = data.map { String(format: "%02x", $0) }.joined()
        self.deviceToken = token
        self.isRegistered = true
        Self.logger.info("Device token: \(token.prefix(16))...")

        // Try to send now. If the server isn't connected yet this is a no-op,
        // but `uploadStoredTokenIfNeeded()` will retry when the connection
        // comes up.
        Task {
            await sendTokenToServer(token)
        }
    }

    /// Called by AppDelegate when registration fails.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        Self.logger.error("Push registration failed: \(error)")
        self.isRegistered = false
    }

    /// Upload the cached device token to whichever server is active now.
    /// Call this from AppState.connectToServer after a successful auth — that
    /// way the token always lands on the server, even when the push callback
    /// fires before the socket is connected (which is the common case on
    /// launch).
    func uploadStoredTokenIfNeeded() async {
        guard let token = deviceToken else {
            Self.logger.info("uploadStoredTokenIfNeeded: no device token yet")
            return
        }
        await sendTokenToServer(token)
    }

    /// Send the device token to the CodeLight Server.
    private func sendTokenToServer(_ token: String) async {
        guard let serverUrl = await AppState.shared.currentServerUrl else {
            Self.logger.info("sendTokenToServer: no currentServerUrl yet, will retry on connect")
            return
        }
        guard let authToken = KeyManager(serviceName: "com.codelight.app").loadToken(forServer: serverUrl) else {
            Self.logger.warning("sendTokenToServer: no auth token for \(serverUrl)")
            return
        }

        let url = URL(string: "\(serverUrl)/v1/push-tokens")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["token": token])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                Self.logger.info("Push token registered with server (\(token.prefix(12)))")
            } else if let httpResponse = response as? HTTPURLResponse {
                Self.logger.warning("Push token upload returned \(httpResponse.statusCode)")
            }
        } catch {
            Self.logger.error("Failed to register push token: \(error)")
        }
    }
}
