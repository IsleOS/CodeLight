import SwiftUI
import UIKit
import CodeLightCrypto

/// Settings — backend info, paired Macs management, security, language, about.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tokenExpiryDays") private var tokenExpiryDays: Int = 30
    @State private var showCleanupAlert = false
    @State private var showResetConfirm = false
    @State private var reconnectStatus: ActionStatus = .idle
    @State private var cleanupStatus: ActionStatus = .idle
    @State private var showPrivacy = false

    /// Transient status shown next to an action button.
    enum ActionStatus: Equatable {
        case idle
        case running
        case success(String)
        case failure(String)
    }
    @State private var notificationPrefs = SocketClient.NotificationPrefs(
        notificationsEnabled: true,
        notifyOnCompletion: false,
        notifyOnApproval: false,
        notifyOnError: false
    )
    @State private var prefsLoaded = false

    private let expiryOptions = [7, 14, 30, 90, 180, 365]


    var body: some View {
        List {
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
                            Haptics.selection()
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

            // Subscription
            Section {
                HStack {
                    Label(String(localized: "subscription"), systemImage: "crown")
                    Spacer()
                    subscriptionBadge
                }

                if appState.subscriptionStatus != "active" && !StoreManager.shared.isPurchased {
                    Button {
                        appState.subscriptionReason = .voluntary
                        // Dismiss Settings first, then LinkedMacsListView's
                        // sheet onDismiss will present the paywall from the
                        // correct presentation hierarchy.
                        appState.pendingSubscriptionPaywall = true
                        dismiss()
                    } label: {
                        Label(String(localized: "upgrade_to_lifetime"), systemImage: "star.fill")
                            .foregroundStyle(Theme.brand)
                    }
                }
            } header: {
                Text(String(localized: "subscription"))
            } footer: {
                Text(String(localized: "subscription_footer"))
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

            // Reconnect
            Section {
                Button {
                    Task { await doReconnect() }
                } label: {
                    HStack {
                        Label(String(localized: "reconnect"), systemImage: "arrow.clockwise")
                        Spacer()
                        statusView(reconnectStatus)
                    }
                }
                .disabled(reconnectStatus == .running)
            } footer: {
                Text(String(localized: "reconnect_footer"))
            }

            // Cleanup
            Section {
                Button {
                    showCleanupAlert = true
                } label: {
                    HStack {
                        Label(String(localized: "cleanup_inactive_sessions"), systemImage: "trash.circle")
                        Spacer()
                        statusView(cleanupStatus)
                    }
                }
                .disabled(cleanupStatus == .running)
            } footer: {
                Text(String(localized: "cleanup_footer"))
            }

            // Reset (destructive)
            Section {
                Button(role: .destructive) {
                    Haptics.warning()
                    showResetConfirm = true
                } label: {
                    Label(String(localized: "reset_backend"), systemImage: "wifi.slash")
                }
            } header: {
                Text(String(localized: "actions"))
            } footer: {
                Text(String(localized: "reset_footer"))
            }

            // Language — deep-link to iOS Settings → CodeLight → Language.
            // We deliberately do NOT have an in-app picker because:
            //   1. iOS reads AppleLanguages once at launch via Bundle.main, so
            //      live switching doesn't relocalize the running view tree.
            //   2. Calling exit(0) to force a relaunch is explicitly discouraged
            //      by Apple HIG ("People interpret this as a crash") and risks
            //      App Review rejection.
            // The system Settings page handles the entire flow natively: user
            // picks a language, iOS relaunches the app cleanly. Zero review
            // risk, zero custom code, more native UX.
            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label(String(localized: "language"), systemImage: "globe")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } header: {
                Text(String(localized: "language"))
            } footer: {
                Text(String(localized: "language_settings_footer"))
            }

            // Notifications
            Section {
                // System permission status — tap to open iOS notification settings
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        Label(String(localized: "push_notifications"), systemImage: "bell.badge")
                        Spacer()
                        Text(PushManager.shared.systemPermissionGranted ? String(localized: "enabled") : String(localized: "disabled"))
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.up.forward.app")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)

                // Master kill-switch: when off, the server skips ALL pushes
                // for this device regardless of the per-kind toggles below.
                Toggle(isOn: Binding(
                    get: { notificationPrefs.notificationsEnabled },
                    set: { newValue in
                        notificationPrefs.notificationsEnabled = newValue
                        Task { await syncPrefs() }
                    }
                )) {
                    Label {
                        Text(String(localized: "enable_all_notifications"))
                    } icon: {
                        Image(systemName: "bell.slash")
                    }
                }
                .disabled(!prefsLoaded || !PushManager.shared.systemPermissionGranted)

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
                .disabled(!prefsLoaded || !notificationPrefs.notificationsEnabled)

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
                .disabled(!prefsLoaded || !notificationPrefs.notificationsEnabled)

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
                .disabled(!prefsLoaded || !notificationPrefs.notificationsEnabled)
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

                if let codelightURL = URL(string: "https://github.com/xmqywx/CodeLight") {
                    Link(destination: codelightURL) {
                        Label(String(localized: "github"), systemImage: "link")
                    }
                }

                if let mioIslandURL = URL(string: "https://github.com/MioMioOS/MioIsland") {
                    Link(destination: mioIslandURL) {
                        Label(String(localized: "codeisland_mac_companion"), systemImage: "desktopcomputer")
                    }
                }

                Button {
                    showPrivacy = true
                } label: {
                    HStack {
                        Label(String(localized: "privacy_policy"), systemImage: "hand.raised")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
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
                Haptics.rigid()
                Task {
                    await appState.reset()
                    dismiss()
                }
            }
        } message: {
            Text(String(localized: "reset_backend_confirm"))
        }
        .sheet(isPresented: $showPrivacy) {
            PrivacyPolicyView()
        }
        .task {
            await loadPrefs()
        }
    }

    // MARK: - Subscription Badge

    @ViewBuilder
    private var subscriptionBadge: some View {
        let status = appState.subscriptionStatus
        if StoreManager.shared.isPurchased || (status == "active" && appState.trialDaysLeft == nil) {
            Text(String(localized: "status_active"))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.success)
        } else if status == "active", let days = appState.trialDaysLeft {
            Text(String(format: NSLocalizedString("redeemed_days_left_format", comment: ""), days))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.success)
        } else if status == "trial" {
            let daysText = appState.trialDaysLeft.map { String(format: NSLocalizedString("trial_days_left_format", comment: ""), $0) } ?? String(localized: "status_trial")
            Text(daysText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.warning)
        } else if status == "expired" {
            Text(String(localized: "status_expired"))
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(Theme.danger)
        } else if status == "unknown" || status == "none" {
            ProgressView()
                .controlSize(.mini)
        }
    }

    // MARK: - Action status UI

    @ViewBuilder
    private func statusView(_ status: ActionStatus) -> some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .success(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            case .failure(let msg):
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: status)
    }

    // MARK: - Actions

    private func doReconnect() async {
        let target = appState.currentServerUrl ?? appState.lastUsedServerUrl ?? appState.linkedMacs.first?.serverUrl
        guard let url = target else {
            Haptics.error()
            reconnectStatus = .failure(String(localized: "no_server_to_connect"))
            return
        }
        Haptics.medium()
        reconnectStatus = .running
        await appState.connectToServer(url: url)
        if appState.isConnected {
            Haptics.success()
            reconnectStatus = .success(String(localized: "reconnected_success"))
        } else {
            Haptics.error()
            reconnectStatus = .failure(String(localized: "reconnect_failed"))
        }
        // Auto-clear the status badge after a moment
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        if case .success = reconnectStatus { reconnectStatus = .idle }
        if case .failure = reconnectStatus { reconnectStatus = .idle }
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
        guard let socket = appState.socket else {
            reconnectStatus = .failure(String(localized: "not_connected"))
            return
        }
        do {
            _ = try await socket.updateNotificationPrefs(notificationPrefs)
        } catch {
            // Revert the toggle the user just flipped so UI stays in sync with server.
            notificationPrefs = (try? await socket.fetchNotificationPrefs()) ?? notificationPrefs
            reconnectStatus = .failure(String(localized: "sync_failed"))
        }
    }

    private func runCleanup() async {
        guard let serverUrl = appState.currentServerUrl,
              let token = KeyManager(serviceName: "com.codelight.app").loadToken(forServer: serverUrl) else {
            Haptics.error()
            cleanupStatus = .failure(String(localized: "not_connected"))
            return
        }

        Haptics.medium()
        cleanupStatus = .running

        guard let url = URL(string: "\(serverUrl)/v1/sessions/cleanup") else {
            cleanupStatus = .failure(String(localized: "not_connected"))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["inactiveMinutes": 15])
        // 15s ceiling so a slow/hung server doesn't trap the user in a one-minute
        // spinner with no escape — URLSession's default timeout is 60s.
        request.timeoutInterval = 15

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let cleaned = result["cleaned"] as? Int {
                if cleaned == 0 {
                    cleanupStatus = .success(String(localized: "cleanup_no_sessions"))
                } else {
                    cleanupStatus = .success(String(format: String(localized: "cleanup_result"), cleaned))
                }
                Haptics.success()
                if let socket = appState.socket {
                    appState.sessions = (try? await socket.fetchSessions()) ?? []
                }
            } else {
                Haptics.error()
                cleanupStatus = .failure(String(localized: "bad_response"))
            }
        } catch {
            Haptics.error()
            cleanupStatus = .failure(error.localizedDescription)
        }

        // Auto-clear the status after a short delay
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if case .success = cleanupStatus { cleanupStatus = .idle }
        if case .failure = cleanupStatus { cleanupStatus = .idle }
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
