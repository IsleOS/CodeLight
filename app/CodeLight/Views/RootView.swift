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
                        await appState.connect()
                        if !appState.isConnected {
                            errorMessage = String(localized: "could_not_connect")
                            showError = true
                        }
                    }
            }
        }
        .preferredColorScheme(.dark)
    }

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
                        appState.reset()
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
