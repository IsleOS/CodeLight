import SwiftUI
import CodeLightCrypto

/// Settings — backend info, paired Macs management, security, language, about.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tokenExpiryDays") private var tokenExpiryDays: Int = 30
    @State private var selectedLanguage: String = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? ""
    @State private var showCleanupAlert = false
    @State private var cleanupResult: String? = nil
    @State private var showResetConfirm = false
    @State private var notificationPrefs = SocketClient.NotificationPrefs(
        notifyOnCompletion: false,
        notifyOnApproval: false,
        notifyOnError: false
    )
    @State private var prefsLoaded = false

    private let expiryOptions = [7, 14, 30, 90, 180, 365]

    private func applyLanguage(_ lang: String) {
        if lang.isEmpty {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang], forKey: "AppleLanguages")
        }
    }

    var body: some View {
        List {
            // Connection status (current active socket)
            Section {
                HStack {
                    Label(String(localized: "current_server"), systemImage: "server.rack")
                    Spacer()
                    Text(appState.currentServerUrl.flatMap { URL(string: $0)?.host } ?? "—")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                HStack {
                    Label(String(localized: "status"), systemImage: "circle.fill")
                        .foregroundStyle(appState.isConnected ? .green : .red)
                    Spacer()
                    Text(appState.isConnected ? String(localized: "connected") : String(localized: "disconnected"))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(String(localized: "connection"))
            }

            // All known servers (one row per unique server URL)
            Section {
                if appState.knownServerUrls.isEmpty {
                    Text(String(localized: "no_servers_yet"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.knownServerUrls, id: \.self) { url in
                        let macCount = appState.linkedMacs.filter { $0.serverUrl == url }.count
                        Button {
                            Task { await appState.switchServerIfNeeded(to: url) }
                        } label: {
                            HStack {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(url == appState.currentServerUrl ? Theme.brand : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(string: url)?.host ?? url)
                                        .foregroundStyle(.primary)
                                    Text(String(format: NSLocalizedString("n_macs_format", comment: ""), macCount))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if url == appState.currentServerUrl && appState.isConnected {
                                    Text(String(localized: "active"))
                                        .font(.caption2)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "servers"))
            } footer: {
                Text(String(localized: "tap_server_to_switch"))
            }

            // Paired Macs (flat list, shows server host subtitle)
            Section {
                if appState.linkedMacs.isEmpty {
                    Text(String(localized: "no_paired_macs"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.linkedMacs) { mac in
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(Theme.brand)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mac.name)
                                Text(mac.serverHost)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await appState.unlinkMac(mac) }
                            } label: {
                                Label(String(localized: "unpair"), systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text(String(localized: "paired_macs"))
            } footer: {
                Text(String(localized: "swipe_to_unpair"))
            }

            // Security
            Section {
                Picker(selection: $tokenExpiryDays) {
                    ForEach(expiryOptions, id: \.self) { days in
                        Text(expiryLabel(days)).tag(days)
                    }
                } label: {
                    Label(String(localized: "token_expiry"), systemImage: "clock.badge.checkmark")
                }
            } header: {
                Text(String(localized: "security"))
            } footer: {
                Text(String(localized: "token_expiry_footer"))
            }

            // Actions
            Section {
                Button {
                    Task { await appState.connect() }
                } label: {
                    Label(String(localized: "reconnect"), systemImage: "arrow.clockwise")
                }

                Button {
                    showCleanupAlert = true
                } label: {
                    Label(String(localized: "cleanup_inactive_sessions"), systemImage: "trash.circle")
                }

                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label(String(localized: "reset_backend"), systemImage: "wifi.slash")
                }
            } header: {
                Text(String(localized: "actions"))
            } footer: {
                if let cleanupResult {
                    Text(cleanupResult)
                        .foregroundStyle(.green)
                }
            }

            // Language
            Section {
                Picker(selection: $selectedLanguage) {
                    Text("Auto (System)").tag("")
                    Text("English").tag("en")
                    Text("简体中文").tag("zh-Hans")
                } label: {
                    Label(String(localized: "language"), systemImage: "globe")
                }
                .onChange(of: selectedLanguage) {
                    applyLanguage(selectedLanguage)
                }
            } header: {
                Text(String(localized: "language"))
            }

            // Notifications
            Section {
                HStack {
                    Label(String(localized: "push_notifications"), systemImage: "bell.badge")
                    Spacer()
                    Text(PushManager.shared.isRegistered ? String(localized: "enabled") : String(localized: "disabled"))
                        .foregroundStyle(.secondary)
                }

                if !PushManager.shared.isRegistered {
                    Button {
                        Task { await PushManager.shared.requestPermission() }
                    } label: {
                        Text(String(localized: "enable_notifications"))
                    }
                }

                Toggle(isOn: Binding(
                    get: { notificationPrefs.notifyOnCompletion },
                    set: { newValue in
                        notificationPrefs.notifyOnCompletion = newValue
                        Task { await syncPrefs() }
                    }
                )) {
                    Label {
                        Text(String(localized: "notify_on_completion"))
                    } icon: {
                        Image(systemName: "checkmark.circle")
                    }
                }
                .disabled(!prefsLoaded)

                Toggle(isOn: Binding(
                    get: { notificationPrefs.notifyOnApproval },
                    set: { newValue in
                        notificationPrefs.notifyOnApproval = newValue
                        Task { await syncPrefs() }
                    }
                )) {
                    Label {
                        Text(String(localized: "notify_on_approval"))
                    } icon: {
                        Image(systemName: "hand.raised")
                    }
                }
                .disabled(!prefsLoaded)

                Toggle(isOn: Binding(
                    get: { notificationPrefs.notifyOnError },
                    set: { newValue in
                        notificationPrefs.notifyOnError = newValue
                        Task { await syncPrefs() }
                    }
                )) {
                    Label {
                        Text(String(localized: "notify_on_error"))
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                }
                .disabled(!prefsLoaded)
            } header: {
                Text(String(localized: "notifications"))
            } footer: {
                Text(String(localized: "notify_footer"))
            }

            // About
            Section {
                HStack {
                    Label(String(localized: "version"), systemImage: "info.circle")
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                        .foregroundStyle(.secondary)
                }

                Link(destination: URL(string: "https://github.com/xmqywx/CodeLight")!) {
                    Label(String(localized: "github"), systemImage: "link")
                }

                Link(destination: URL(string: "https://github.com/xmqywx/CodeIsland")!) {
                    Label(String(localized: "codeisland_mac_companion"), systemImage: "desktopcomputer")
                }

                Link(destination: URL(string: "https://github.com/xmqywx/CodeLight/blob/main/PRIVACY.md")!) {
                    Label(String(localized: "privacy_policy"), systemImage: "hand.raised")
                }
            } header: {
                Text(String(localized: "about"))
            } footer: {
                Text(String(localized: "about_footer"))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
        .navigationTitle(String(localized: "settings"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(String(localized: "done")) { dismiss() }
            }
        }
        .alert(String(localized: "cleanup_inactive_sessions"), isPresented: $showCleanupAlert) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "clean_now"), role: .destructive) {
                Task { await runCleanup() }
            }
        } message: {
            Text(String(localized: "cleanup_confirm_message"))
        }
        .alert(String(localized: "reset_backend"), isPresented: $showResetConfirm) {
            Button(String(localized: "cancel"), role: .cancel) {}
            Button(String(localized: "reset"), role: .destructive) {
                appState.reset()
                dismiss()
            }
        } message: {
            Text(String(localized: "reset_backend_confirm"))
        }
        .task {
            await loadPrefs()
        }
    }

    // MARK: - Notification Prefs

    private func loadPrefs() async {
        guard let socket = appState.socket else { return }
        if let prefs = try? await socket.fetchNotificationPrefs() {
            await MainActor.run {
                notificationPrefs = prefs
                prefsLoaded = true
            }
        } else {
            await MainActor.run { prefsLoaded = true } // enable toggles with defaults
        }
    }

    private func syncPrefs() async {
        guard let socket = appState.socket else { return }
        _ = try? await socket.updateNotificationPrefs(notificationPrefs)
    }

    private func runCleanup() async {
        guard let serverUrl = appState.currentServerUrl,
              let token = KeyManager(serviceName: "com.codelight.app").loadToken(forServer: serverUrl) else {
            return
        }

        let url = URL(string: "\(serverUrl)/v1/sessions/cleanup")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["inactiveMinutes": 15])

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cleaned = result["cleaned"] as? Int {
                cleanupResult = String(format: String(localized: "cleanup_result"), cleaned)

                if let socket = appState.socket {
                    appState.sessions = (try? await socket.fetchSessions()) ?? []
                }
            }
        } catch {
            cleanupResult = "Error: \(error.localizedDescription)"
        }
    }

    private func expiryLabel(_ days: Int) -> String {
        switch days {
        case 7: return String(localized: "7_days")
        case 14: return String(localized: "14_days")
        case 30: return String(localized: "30_days")
        case 90: return String(localized: "90_days")
        case 180: return String(localized: "180_days")
        case 365: return String(localized: "1_year")
        default: return "\(days)d"
        }
    }
}
