import SwiftUI

/// Root navigation:
/// - No backend yet → `PairingView` (first pair sets the backend implicitly)
/// - Has backend, not connected → loading + auto-connect
/// - Has backend, connected → `LinkedMacsListView`
struct RootView: View {
    @EnvironmentObject var appState: AppState
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            if appState.linkedMacs.isEmpty && appState.lastUsedServerUrl == nil {
                // Fresh install (no Macs paired, no server history) → pairing flow
                PairingView()
            } else if appState.isConnected || !appState.linkedMacs.isEmpty {
                // Either connected, OR we have cached Macs to show even while offline
                LinkedMacsListView()
            } else {
                connectingView
                    .task {
                        // 30s watchdog: if connect() hasn't returned and the
                        // socket is still down, surface the error UI so the
                        // user has a way out (Try Again / Reset). Without
                        // this the spinner runs forever on stuck DNS / dead
                        // server / half-open socket — which is both a UX hole
                        // and an App Review red flag (Guideline 2.1).
                        let watchdog = Task {
                            try? await Task.sleep(nanoseconds: 30_000_000_000)
                            if !Task.isCancelled, !appState.isConnected, !showError {
                                errorMessage = String(localized: "could_not_connect")
                                showError = true
                            }
                        }
                        await appState.connect()
                        watchdog.cancel()
                        if !appState.isConnected, !showError {
                            errorMessage = String(localized: "could_not_connect")
                            showError = true
                        }
                    }
            }
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $appState.activeSheet) { sheet in
            switch sheet {
            case .subscription:
                SubscriptionView(reason: appState.subscriptionReason)
                    .environmentObject(appState)
            case .deviceLimit:
                DeviceLimitView()
            }
        }
        .alert(String(localized: "device_reregistered_title"), isPresented: $appState.showDeviceReregistered) {
            Button(String(localized: "device_reregistered_repair")) {
                Task {
                    // Remove the stale Mac pairing
                    if let oldId = appState.deviceReregisteredOldDeviceId,
                       let staleMac = appState.linkedMacs.first(where: { $0.deviceId == oldId }) {
                        await appState.unlinkMac(staleMac)
                    }
                    // If no Macs left, RootView automatically shows PairingView
                    // If other Macs remain, user can tap + to add new pairing
                    appState.deviceReregisteredOldDeviceId = nil
                }
            }
            Button(String(localized: "ok"), role: .cancel) {
                appState.deviceReregisteredOldDeviceId = nil
            }
        } message: {
            Text(String(format: String(localized: "device_reregistered_message %@"), appState.deviceReregisteredMacName))
        }
    }

    // MARK: - Subscription Banner


    private var connectingView: some View {
        VStack(spacing: 24) {
            Spacer()

            if showError {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                VStack(spacing: 8) {
                    Text(String(localized: "connection_failed"))
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    Button {
                        showError = false
                        Task {
                            await appState.connect()
                            if !appState.isConnected {
                                showError = true
                            }
                        }
                    } label: {
                        Label(String(localized: "try_again"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        Task { await appState.reset() }
                    } label: {
                        Text(String(localized: "reset_connection"))
                    }
                }
                .padding(.horizontal, 40)
            } else {
                ProgressView()
                    .scaleEffect(1.2)

                Text(String(localized: "connecting_to_server"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }
}
